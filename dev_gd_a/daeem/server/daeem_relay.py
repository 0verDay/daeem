#!/usr/bin/env python3
"""DAEEM co-op relay: one small, zero-dependency WebSocket relay.

The relay knows only rooms and envelopes. It never imports game logic and never
looks inside `cmd` / `snap` bodies. Run it locally first; deploy later with nssm.

Routes:
  GET /health -> {"ok": true, "rooms": n, "players": n, "uptime": s}
  GET /rooms  -> room codes + counts (no IPs)
  WS  /ws     -> game connection

Wire protocol (client -> relay first):
  {"v":1, "t":"hello", "seq":0, "ts":0, "body":{"build":"coop-m12.2"}}
  {"v":1, "t":"create_room", "body":{"code":"ABC234"}}
  {"v":1, "t":"join_room", "body":{"code":"ABC234"}}
  {"v":1, "t":"ready"}
  {"v":1, "t":"start", ...}       host only, after both ready
  any other type                  forwarded to the other player
"""
from __future__ import annotations

import argparse
import asyncio
import base64
import hashlib
import json
import secrets
import string
import sys
import time
from dataclasses import dataclass, field
from typing import Optional
from urllib.parse import urlsplit

WS_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
PROTOCOL_VERSION = 1
ROOM_ALPHABET = "23456789ABCDEFGHJKLMNPQRSTUVWXYZ"
MAX_HTTP_HEADER = 16 * 1024
MAX_MESSAGE = 16 * 1024 * 1024
MAX_ROOM_CODE_TRIES = 64
DEFAULT_BUILD = "coop-m12.2"
PING_SEC = 20.0
PONG_TIMEOUT_SEC = 60.0


def now_ms() -> int:
    return int(time.time() * 1000)


def make(t: str, body: Optional[dict] = None, seq: int = 0) -> dict:
    return {"v": PROTOCOL_VERSION, "t": t, "seq": seq, "ts": now_ms(), "body": body or {}}


def log(message: str) -> None:
    stamp = time.strftime("%H:%M:%S")
    print(f"[{stamp}] {message}", flush=True)


class ProtocolError(Exception):
    def __init__(self, code: int = 1002, reason: str = "protocol"):
        super().__init__(reason)
        self.code = code
        self.reason = reason


class PeerClosed(Exception):
    pass


async def read_http_request(reader: asyncio.StreamReader):
    raw = await reader.readuntil(b"\r\n\r\n")
    if len(raw) > MAX_HTTP_HEADER:
        raise ProtocolError(1009, "header-too-large")
    text = raw.decode("latin1")
    lines = text.split("\r\n")
    parts = lines[0].split(" ")
    if len(parts) < 2:
        raise ProtocolError(1002, "bad-request")
    method, target = parts[0], parts[1]
    headers: dict[str, str] = {}
    for line in lines[1:]:
        if not line or ":" not in line:
            continue
        name, value = line.split(":", 1)
        headers[name.strip().lower()] = value.strip()
    return method, target, headers


async def send_http(writer: asyncio.StreamWriter, status: str, payload: dict) -> None:
    body = json.dumps(payload, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
    head = (
        f"HTTP/1.1 {status}\r\n"
        "Content-Type: application/json; charset=utf-8\r\n"
        f"Content-Length: {len(body)}\r\n"
        "Connection: close\r\n"
        "\r\n"
    ).encode("latin1")
    writer.write(head + body)
    await writer.drain()


async def write_frame(writer: asyncio.StreamWriter, opcode: int, payload: bytes, fin: bool = True) -> None:
    head = bytearray()
    head.append((0x80 if fin else 0x00) | (opcode & 0x0F))
    length = len(payload)
    if length < 126:
        head.append(length)
    elif length < 65536:
        head.append(126)
        head.extend(length.to_bytes(2, "big"))
    else:
        head.append(127)
        head.extend(length.to_bytes(8, "big"))
    writer.write(bytes(head))
    if payload:
        writer.write(payload)
    await writer.drain()


async def read_frame(reader: asyncio.StreamReader, max_message: int):
    first = await reader.readexactly(2)
    b1, b2 = first[0], first[1]
    fin = bool(b1 & 0x80)
    opcode = b1 & 0x0F
    masked = bool(b2 & 0x80)
    length = b2 & 0x7F
    if length == 126:
        length = int.from_bytes(await reader.readexactly(2), "big")
    elif length == 127:
        length = int.from_bytes(await reader.readexactly(8), "big")
    if length > max_message:
        raise ProtocolError(1009, "message-too-large")
    if opcode >= 0x8 and length > 125:
        raise ProtocolError(1002, "control-frame-too-long")
    if not masked:
        # RFC 6455: every client frame must be masked.
        raise ProtocolError(1002, "unmasked-client-frame")
    mask = await reader.readexactly(4)
    data = bytearray(await reader.readexactly(length))
    for i in range(length):
        data[i] ^= mask[i & 3]
    return fin, opcode, bytes(data)


@dataclass
class Room:
    code: str
    host: "Peer"
    guest: Optional["Peer"] = None
    ready_host: bool = False
    ready_guest: bool = False
    status: str = "lobby"
    created: float = field(default_factory=time.monotonic)

    def other(self, peer: "Peer") -> Optional["Peer"]:
        return self.guest if peer is self.host else self.host


class Peer:
    def __init__(self, relay: "Relay", reader: asyncio.StreamReader, writer: asyncio.StreamWriter):
        self.relay = relay
        self.reader = reader
        self.writer = writer
        self.room: Optional[Room] = None
        self.role = ""
        self.name = ""
        self.build = ""
        self.alive = True
        self.last_pong = time.monotonic()
        self._send_lock = asyncio.Lock()

    async def send_json(self, msg: dict) -> None:
        await self.send_text(json.dumps(msg, ensure_ascii=False, separators=(",", ":")))

    async def send_text(self, text: str) -> None:
        if not self.alive:
            return
        async with self._send_lock:
            try:
                await write_frame(self.writer, 0x1, text.encode("utf-8"))
            except (ConnectionError, RuntimeError):
                self.alive = False

    async def send_ping(self) -> None:
        if not self.alive:
            return
        async with self._send_lock:
            try:
                await write_frame(self.writer, 0x9, b"")
            except (ConnectionError, RuntimeError):
                self.alive = False

    async def close(self, code: int = 1000, reason: str = "") -> None:
        if not self.alive:
            return
        self.alive = False
        payload = code.to_bytes(2, "big") + reason.encode("utf-8")[:123]
        try:
            await write_frame(self.writer, 0x8, payload)
        except (ConnectionError, RuntimeError):
            pass
        try:
            self.writer.close()
            await self.writer.wait_closed()
        except (ConnectionError, RuntimeError):
            pass

    async def _send_pong(self, payload: bytes) -> None:
        async with self._send_lock:
            try:
                await write_frame(self.writer, 0xA, payload)
            except (ConnectionError, RuntimeError):
                self.alive = False

    async def _recv_text(self) -> str:
        started = False
        parts: list[bytes] = []
        total = 0
        while True:
            fin, opcode, payload = await read_frame(self.reader, self.relay.max_message)
            # Any frame proves the connection is alive; pongs are still preferred.
            self.last_pong = time.monotonic()
            if opcode == 0x8:
                # Echo the close frame, then let run() clean the room up.
                code = 1000
                if len(payload) >= 2:
                    code = int.from_bytes(payload[:2], "big")
                await self.close(code, "peer-close")
                raise PeerClosed()
            if opcode == 0x9:
                # Control frames may interleave with a fragmented text message.
                await self._send_pong(payload)
                continue
            if opcode == 0xA:
                self.last_pong = time.monotonic()
                continue
            if opcode == 0x2:
                raise ProtocolError(1003, "binary-unsupported")
            if opcode == 0x1:
                if started:
                    raise ProtocolError(1002, "nested-text-frame")
                started = True
                parts.append(payload)
                total += len(payload)
            elif opcode == 0x0:
                if not started:
                    raise ProtocolError(1002, "continuation-without-start")
                parts.append(payload)
                total += len(payload)
            else:
                raise ProtocolError(1002, "unknown-opcode")
            if total > self.relay.max_message:
                raise ProtocolError(1009, "message-too-large")
            if fin:
                if not started:
                    raise ProtocolError(1002, "empty-message")
                try:
                    return b"".join(parts).decode("utf-8")
                except UnicodeDecodeError as exc:
                    raise ProtocolError(1007, "invalid-utf8") from exc

    async def recv_json(self) -> dict:
        text = await self._recv_text()
        try:
            msg = json.loads(text)
        except json.JSONDecodeError as exc:
            raise ProtocolError(1003, "bad-json") from exc
        if not isinstance(msg, dict):
            raise ProtocolError(1003, "bad-envelope")
        try:
            version = int(msg.get("v", 0))
        except (TypeError, ValueError) as exc:
            raise ProtocolError(1008, "bad-version") from exc
        if version != PROTOCOL_VERSION:
            raise ProtocolError(1008, "bad-version")
        if not isinstance(msg.get("t"), str) or not msg.get("t"):
            raise ProtocolError(1003, "bad-type")
        if not isinstance(msg.get("body"), dict):
            raise ProtocolError(1003, "bad-body")
        return msg

    async def run(self) -> None:
        try:
            first = await self.recv_json()
            if first.get("t") != "hello":
                await self.send_json(make("err", {"code": "hello", "msg": "hello required"}))
                await self.close(1008, "hello required")
                return
            body = first.get("body", {})
            self.build = str(body.get("build", ""))
            self.name = str(body.get("name", ""))[:32]
            if self.relay.build and self.build and self.build != self.relay.build:
                await self.send_json(make("err", {"code": "build", "msg": "build mismatch"}))
                await self.close(1008, "build mismatch")
                return
            await self.send_json(make("hello", {"ok": True, "build": self.relay.build}))
            self.relay.peers.add(self)
            self.relay.log_peer("open", self)
            while self.alive:
                msg = await self.recv_json()
                await self.relay.on_message(self, msg)
        except PeerClosed:
            pass
        except ProtocolError as exc:
            try:
                await self.send_json(make("err", {"code": "protocol", "msg": exc.reason}))
            except Exception:
                pass
            await self.close(exc.code, exc.reason)
        except (asyncio.IncompleteReadError, ConnectionError, RuntimeError):
            pass
        finally:
            await self.relay.drop_peer(self)


class Relay:
    def __init__(self, host: str, port: int, max_rooms: int, build: str, max_message: int):
        self.host = host
        self.port = port
        self.max_rooms = max_rooms
        self.build = build
        self.max_message = max_message
        self.rooms: dict[str, Room] = {}
        self.peers: set[Peer] = set()
        self.started = time.monotonic()
        self._hb_task: Optional[asyncio.Task] = None

    def log_peer(self, action: str, peer: Peer) -> None:
        log(f"{action} peer={id(peer) & 0xFFFF:04x} build={peer.build or '-'} "
            f"room={peer.room.code if peer.room else '-'} role={peer.role or '-'}")

    async def handle_client(self, reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
        try:
            method, target, headers = await read_http_request(reader)
        except (asyncio.IncompleteReadError, ConnectionError, ProtocolError):
            writer.close()
            return
        path = urlsplit(target).path
        if method != "GET":
            await send_http(writer, "405 Method Not Allowed", {"ok": False, "error": "method"})
            writer.close()
            return
        if path == "/health":
            await send_http(writer, "200 OK", self.health())
            writer.close()
            return
        if path == "/rooms":
            await send_http(writer, "200 OK", {"ok": True, "rooms": self.rooms_info()})
            writer.close()
            return
        if path != "/ws":
            await send_http(writer, "404 Not Found", {"ok": False, "error": "not found"})
            writer.close()
            return
        if headers.get("upgrade", "").lower() != "websocket":
            await send_http(writer, "400 Bad Request", {"ok": False, "error": "upgrade"})
            writer.close()
            return
        key = headers.get("sec-websocket-key", "")
        if not key:
            await send_http(writer, "400 Bad Request", {"ok": False, "error": "key"})
            writer.close()
            return
        accept = base64.b64encode(hashlib.sha1((key + WS_GUID).encode("ascii")).digest()).decode("ascii")
        response = (
            "HTTP/1.1 101 Switching Protocols\r\n"
            "Upgrade: websocket\r\n"
            "Connection: Upgrade\r\n"
            f"Sec-WebSocket-Accept: {accept}\r\n"
            "\r\n"
        ).encode("latin1")
        writer.write(response)
        await writer.drain()
        peer = Peer(self, reader, writer)
        await peer.run()

    def health(self) -> dict:
        return {
            "ok": True,
            "rooms": len(self.rooms),
            "players": len(self.peers),
            "uptime": round(time.monotonic() - self.started, 1),
            "build": self.build,
        }

    def rooms_info(self) -> list[dict]:
        out = []
        for room in self.rooms.values():
            out.append({
                "code": room.code,
                "host": room.host is not None,
                "guest": room.guest is not None,
                "status": room.status,
            })
        return out

    async def on_message(self, peer: Peer, msg: dict) -> None:
        t = str(msg.get("t", ""))
        body = msg.get("body", {})
        if t == "hello":
            return
        if t == "create_room":
            await self._create_room(peer, body, msg)
        elif t == "join_room":
            await self._join_room(peer, body, msg)
        elif t == "ready":
            await self._ready(peer)
        elif t == "start":
            await self._start(peer, msg)
        elif t == "bye":
            await self._bye(peer, msg)
        elif t == "ping":
            await peer.send_json(make("pong", {"ts": now_ms()}))
        else:
            await self._forward(peer, msg)

    async def _create_room(self, peer: Peer, body: dict, msg: dict) -> None:
        if peer.room is not None:
            await peer.send_json(make("err", {"code": "in_room", "msg": "already in room"}))
            return
        if len(self.rooms) >= self.max_rooms:
            await peer.send_json(make("err", {"code": "rooms_full", "msg": "too many rooms"}))
            return
        requested = str(body.get("code", "")).strip().upper()
        code = ""
        if requested:
            if not valid_room_code(requested):
                await peer.send_json(make("err", {"code": "code", "msg": "bad room code"}))
                return
            if requested in self.rooms:
                await peer.send_json(make("err", {"code": "code_taken", "msg": "room exists"}))
                return
            code = requested
        else:
            code = self._new_code()
            if not code:
                await peer.send_json(make("err", {"code": "code", "msg": "no room code"}))
                return
        room = Room(code=code, host=peer, status="lobby")
        self.rooms[code] = room
        peer.room = room
        peer.role = "host"
        peer.name = str(body.get("name", "host"))[:32]
        log(f"room create code={code} host={id(peer) & 0xFFFF:04x}")
        await self._send_state(room)

    async def _join_room(self, peer: Peer, body: dict, msg: dict) -> None:
        if peer.room is not None:
            await peer.send_json(make("err", {"code": "in_room", "msg": "already in room"}))
            return
        code = str(body.get("code", "")).strip().upper()
        if not valid_room_code(code):
            await peer.send_json(make("err", {"code": "code", "msg": "bad room code"}))
            return
        room = self.rooms.get(code)
        if room is None:
            await peer.send_json(make("err", {"code": "no_room", "msg": "room not found"}))
            return
        if room.guest is not None:
            await peer.send_json(make("err", {"code": "room_full", "msg": "room full"}))
            return
        room.guest = peer
        room.status = "full"
        peer.room = room
        peer.role = "guest"
        peer.name = str(body.get("name", "guest"))[:32]
        log(f"room join code={code} guest={id(peer) & 0xFFFF:04x}")
        await self._send_state(room)

    async def _ready(self, peer: Peer) -> None:
        room = peer.room
        if room is None:
            await peer.send_json(make("err", {"code": "no_room", "msg": "no room"}))
            return
        if peer.role == "host":
            room.ready_host = True
        elif peer.role == "guest":
            room.ready_guest = True
        if room.host is not None and room.guest is not None and room.ready_host and room.ready_guest:
            room.status = "ready"
        log(f"ready code={room.code} role={peer.role} both={room.ready_host and room.ready_guest}")
        await self._send_state(room)

    async def _start(self, peer: Peer, msg: dict) -> None:
        room = peer.room
        if room is None or peer.role != "host" or room.guest is None:
            await peer.send_json(make("err", {"code": "start", "msg": "not ready"}))
            return
        if not (room.ready_host and room.ready_guest):
            await peer.send_json(make("err", {"code": "start", "msg": "players not ready"}))
            return
        room.status = "playing"
        log(f"room start code={room.code}")
        await room.guest.send_json(msg)
        await self._send_state(room)

    async def _bye(self, peer: Peer, msg: dict) -> None:
        room = peer.room
        if room is None:
            return
        reason = str(msg.get("body", {}).get("reason", "left"))
        if peer.role == "host":
            # _close_room notifies the guest (and the departing host; a dead
            # writer is ignored).
            await self._close_room(room, reason)
        else:
            other = room.other(peer)
            if other is not None:
                await other.send_json(make("bye", {"reason": reason}))
            room.guest = None
            room.ready_guest = False
            room.status = "lobby"
            peer.room = None
            if room.host is not None:
                await self._send_state(room)

    async def _forward(self, peer: Peer, msg: dict) -> None:
        room = peer.room
        if room is None:
            await peer.send_json(make("err", {"code": "no_room", "msg": "join a room first"}))
            return
        other = room.other(peer)
        if other is None:
            await peer.send_json(make("err", {"code": "peer", "msg": "peer not connected"}))
            return
        await other.send_json(msg)

    async def _send_state(self, room: Room) -> None:
        state = {
            "code": room.code,
            "host": room.host is not None,
            "guest": room.guest is not None,
            "ready_host": room.ready_host,
            "ready_guest": room.ready_guest,
            "status": room.status,
        }
        if room.host is not None:
            await room.host.send_json(make("room_state", state))
        if room.guest is not None:
            await room.guest.send_json(make("room_state", state))

    async def _close_room(self, room: Room, reason: str) -> None:
        self.rooms.pop(room.code, None)
        for peer in (room.host, room.guest):
            if peer is None:
                continue
            peer.room = None
            try:
                await peer.send_json(make("bye", {"reason": reason}))
            except Exception:
                pass
            await peer.close(1000, reason)
        log(f"room close code={room.code} reason={reason}")

    async def drop_peer(self, peer: Peer) -> None:
        self.peers.discard(peer)
        room = peer.room
        if room is None:
            return
        log(f"disconnect peer={id(peer) & 0xFFFF:04x} room={room.code} role={peer.role}")
        if peer.role == "host":
            await self._close_room(room, "host_left")
        elif peer.role == "guest":
            room.guest = None
            room.ready_guest = False
            room.status = "lobby"
            if room.host is not None:
                await room.host.send_json(make("bye", {"reason": "guest_left"}))
                await self._send_state(room)

    def _new_code(self) -> str:
        for _ in range(MAX_ROOM_CODE_TRIES):
            code = "".join(secrets.choice(ROOM_ALPHABET) for _ in range(6))
            if code not in self.rooms:
                return code
        return ""

    async def heartbeat(self) -> None:
        while True:
            await asyncio.sleep(PING_SEC)
            now = time.monotonic()
            for peer in list(self.peers):
                if now - peer.last_pong > PONG_TIMEOUT_SEC:
                    log(f"heartbeat timeout peer={id(peer) & 0xFFFF:04x}")
                    await peer.close(1001, "timeout")
                else:
                    await peer.send_ping()


def valid_room_code(code: str) -> bool:
    return len(code) == 6 and all(c in ROOM_ALPHABET for c in code)


async def amain(args: argparse.Namespace) -> None:
    relay = Relay(args.host, args.port, args.max_rooms, args.build, args.max_message)
    server = await asyncio.start_server(relay.handle_client, args.host, args.port)
    relay._hb_task = asyncio.create_task(relay.heartbeat())
    ports = []
    for sock in server.sockets or []:
        ports.append(sock.getsockname()[1])
    for port in ports:
        print(f"LISTEN {args.host}:{port}", flush=True)
    log(f"relay build={args.build} rooms={args.max_rooms} max_message={args.max_message}")
    async with server:
        await server.serve_forever()


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="DAEEM co-op WebSocket relay")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8770)
    parser.add_argument("--max-rooms", type=int, default=64)
    parser.add_argument("--build", default=DEFAULT_BUILD)
    parser.add_argument("--max-message", type=int, default=MAX_MESSAGE)
    return parser.parse_args(argv)


def main() -> int:
    args = parse_args(sys.argv[1:])
    try:
        asyncio.run(amain(args))
    except KeyboardInterrupt:
        return 0
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
