#!/usr/bin/env python3
"""Tiny standard-library WebSocket client for relay tests and local probes.

This is deliberately not a general-purpose client: HTTP/1.1 handshake, masked
client frames, text fragmentation, ping/pong and close, no TLS and no extensions.
"""
from __future__ import annotations

import base64
import hashlib
import json
import os
import socket
import struct
import time
from typing import Optional

WS_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"


class WSClosed(Exception):
    def __init__(self, code: int = 1000, reason: str = ""):
        super().__init__(reason)
        self.code = code
        self.reason = reason


class WSClient:
    def __init__(self, host: str, port: int, path: str = "/ws", timeout: float = 5.0):
        self.sock = socket.create_connection((host, port), timeout=timeout)
        self.sock.settimeout(timeout)
        self._buf = b""
        key = base64.b64encode(os.urandom(16)).decode("ascii")
        request = (
            f"GET {path} HTTP/1.1\r\n"
            f"Host: {host}:{port}\r\n"
            "Upgrade: websocket\r\n"
            "Connection: Upgrade\r\n"
            f"Sec-WebSocket-Key: {key}\r\n"
            "Sec-WebSocket-Version: 13\r\n"
            "\r\n"
        )
        self.sock.sendall(request.encode("ascii"))
        head = self._read_until(b"\r\n\r\n")
        text = head.decode("latin1")
        if " 101 " not in text.split("\r\n", 1)[0]:
            raise RuntimeError(f"handshake failed: {text.splitlines()[0] if text else 'empty'}")
        expected = base64.b64encode(
            hashlib.sha1((key + WS_GUID).encode("ascii")).digest()
        ).decode("ascii")
        if expected not in text:
            raise RuntimeError("bad Sec-WebSocket-Accept")

    @classmethod
    def from_url(cls, url: str, timeout: float = 5.0) -> "WSClient":
        from urllib.parse import urlsplit

        u = urlsplit(url)
        if u.scheme != "ws":
            raise ValueError("only ws:// is supported by this helper")
        return cls(u.hostname or "127.0.0.1", u.port or 80, u.path or "/ws", timeout)

    def _read_exact(self, n: int) -> bytes:
        out = bytearray()
        while len(out) < n:
            if self._buf:
                take = min(n - len(out), len(self._buf))
                out.extend(self._buf[:take])
                self._buf = self._buf[take:]
                continue
            chunk = self.sock.recv(max(4096, n - len(out)))
            if not chunk:
                raise WSClosed(1006, "socket closed")
            self._buf += chunk
        return bytes(out)

    def _read_until(self, marker: bytes) -> bytes:
        while marker not in self._buf:
            chunk = self.sock.recv(4096)
            if not chunk:
                raise WSClosed(1006, "socket closed")
            self._buf += chunk
            if len(self._buf) > 65536:
                raise RuntimeError("header too large")
        idx = self._buf.index(marker) + len(marker)
        out = self._buf[:idx]
        self._buf = self._buf[idx:]
        return out

    def _read_frame(self):
        first = self._read_exact(2)
        b1, b2 = first[0], first[1]
        fin = bool(b1 & 0x80)
        opcode = b1 & 0x0F
        masked = bool(b2 & 0x80)
        length = b2 & 0x7F
        if length == 126:
            length = struct.unpack("!H", self._read_exact(2))[0]
        elif length == 127:
            length = struct.unpack("!Q", self._read_exact(8))[0]
        mask = self._read_exact(4) if masked else b""
        data = bytearray(self._read_exact(length))
        if masked:
            for i in range(length):
                data[i] ^= mask[i & 3]
        return fin, opcode, bytes(data)

    def _read_text(self) -> str:
        started = False
        parts: list[bytes] = []
        while True:
            fin, opcode, payload = self._read_frame()
            if opcode == 0x8:
                code = int.from_bytes(payload[:2], "big") if len(payload) >= 2 else 1000
                reason = payload[2:].decode("utf-8", "replace") if len(payload) > 2 else ""
                raise WSClosed(code, reason)
            if opcode == 0x9:
                self.send_frame(0xA, payload)
                continue
            if opcode == 0xA:
                continue
            if opcode == 0x1:
                started = True
                parts.append(payload)
            elif opcode == 0x0:
                if not started:
                    raise RuntimeError("bad continuation")
                parts.append(payload)
            else:
                raise RuntimeError(f"unexpected opcode {opcode}")
            if fin:
                return b"".join(parts).decode("utf-8")

    def recv_json(self, timeout: Optional[float] = None) -> dict:
        if timeout is not None:
            self.sock.settimeout(timeout)
        text = self._read_text()
        return json.loads(text)

    def recv_until(self, predicate, timeout: float = 5.0):
        deadline = time.monotonic() + timeout
        while True:
            remain = deadline - time.monotonic()
            if remain <= 0:
                raise TimeoutError("timed out waiting for message")
            msg = self.recv_json(remain)
            if predicate(msg):
                return msg

    def send_frame(self, opcode: int, payload: bytes, mask: bool = True, fin: bool = True) -> None:
        b1 = (0x80 if fin else 0x00) | (opcode & 0x0F)
        head = bytearray([b1])
        length = len(payload)
        flag = 0x80 if mask else 0
        if length < 126:
            head.append(flag | length)
        elif length < 65536:
            head.append(flag | 126)
            head.extend(struct.pack("!H", length))
        else:
            head.append(flag | 127)
            head.extend(struct.pack("!Q", length))
        if mask:
            key = os.urandom(4)
            head.extend(key)
            masked = bytearray(payload)
            for i in range(length):
                masked[i] ^= key[i & 3]
            payload = bytes(masked)
        self.sock.sendall(bytes(head) + payload)

    def send_text(self, text: str, mask: bool = True) -> None:
        self.send_frame(0x1, text.encode("utf-8"), mask=mask)

    def send_json(self, msg: dict) -> None:
        self.send_text(json.dumps(msg, ensure_ascii=False, separators=(",", ":")))

    def send_fragments(self, parts: list[str]) -> None:
        for i, part in enumerate(parts):
            opcode = 0x1 if i == 0 else 0x0
            fin = i == len(parts) - 1
            self.send_frame(opcode, part.encode("utf-8"), fin=fin)

    def close(self, code: int = 1000, reason: str = "") -> None:
        try:
            payload = code.to_bytes(2, "big") + reason.encode("utf-8")[:123]
            self.send_frame(0x8, payload)
        except OSError:
            pass
        try:
            self.sock.close()
        except OSError:
            pass
