#!/usr/bin/env python3
"""Local host/guest probes for the relay.

Usage:
  python probe_relay.py --role host  --url ws://127.0.0.1:8770/ws --room CAMP23
  python probe_relay.py --role guest --url ws://127.0.0.1:8770/ws --room CAMP23

The probes exercise the same envelope/room flow the game will use:
hello -> create/join -> ready -> start -> cmd -> snap -> bye.
"""
from __future__ import annotations

import argparse
import sys
import time

from relay_client import WSClient, WSClosed

BUILD = "coop-m12.2"


def make(t: str, seq: int, body: dict | None = None) -> dict:
    return {"v": 1, "t": t, "seq": seq, "ts": int(time.time() * 1000), "body": body or {}}


def fail(message: str) -> None:
    print(f"PROBE FAIL: {message}", flush=True)
    raise SystemExit(1)


def check(msg: dict) -> dict:
    if msg.get("t") == "err":
        fail(f"relay err: {msg.get('body')}")
    return msg


def recv_until(c: WSClient, t: str, timeout: float = 15.0) -> dict:
    return check(c.recv_until(lambda m: m.get("t") == t, timeout))


def run_host(url: str, room: str) -> None:
    c = WSClient.from_url(url)
    c.send_json(make("hello", 1, {"build": BUILD, "name": "host"}))
    recv_until(c, "hello")
    c.send_json(make("create_room", 2, {"code": room, "name": "host"}))
    state = recv_until(c, "room_state")
    print(f"PROBE host room={state['body'].get('code')}", flush=True)

    c.send_json(make("ready", 3))
    recv_until(c, "room_state")
    print("PROBE host ready", flush=True)

    # Wait until the guest has also pressed ready.
    state = c.recv_until(
        lambda m: m.get("t") == "room_state" and bool(m.get("body", {}).get("ready_guest")),
        15.0,
    )
    check(state)
    print("PROBE host both-ready", flush=True)

    c.send_json(make("start", 4, {
        "campaign": "demo",
        "level_id": "02_twin_line",
        "seats": ["F1", "F2"],
    }))
    print("PROBE host start", flush=True)

    cmd = recv_until(c, "cmd", 15.0)
    print(f"PROBE host got cmd kind={cmd.get('body', {}).get('cmd', {}).get('kind')}", flush=True)
    c.send_json(make("snap", 5, {
        "snap": {"time": 1.0, "units": [], "buildings": [], "zones": []},
    }))
    print("PROBE host snap", flush=True)
    c.send_json(make("bye", 6, {"reason": "host_left"}))
    time.sleep(0.3)
    c.close()
    print("PROBE host OK", flush=True)


def run_guest(url: str, room: str) -> None:
    c = WSClient.from_url(url)
    c.send_json(make("hello", 1, {"build": BUILD, "name": "guest"}))
    recv_until(c, "hello")
    c.send_json(make("join_room", 2, {"code": room, "name": "guest"}))
    state = recv_until(c, "room_state")
    print(f"PROBE guest room={state['body'].get('code')}", flush=True)

    c.send_json(make("ready", 3))
    recv_until(c, "room_state")
    print("PROBE guest ready", flush=True)

    start = recv_until(c, "start", 15.0)
    print(f"PROBE guest start level={start.get('body', {}).get('level_id')}", flush=True)
    c.send_json(make("cmd", 4, {
        "by": "F2",
        "cmd": {"kind": "stop", "ids": [], "faction": "F2"},
    }))
    print("PROBE guest cmd", flush=True)

    snap = recv_until(c, "snap", 15.0)
    print(f"PROBE guest snapped time={snap.get('body', {}).get('snap', {}).get('time')}", flush=True)
    recv_until(c, "bye", 15.0)
    print("PROBE guest bye", flush=True)
    c.close()
    print("PROBE guest OK", flush=True)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--role", choices=["host", "guest"], required=True)
    parser.add_argument("--url", default="ws://127.0.0.1:8770/ws")
    parser.add_argument("--room", default="CAMP23")
    args = parser.parse_args()
    try:
        if args.role == "host":
            run_host(args.url, args.room.upper())
        else:
            run_guest(args.url, args.room.upper())
    except (WSClosed, TimeoutError, OSError) as exc:
        fail(f"{args.role}: {exc}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

