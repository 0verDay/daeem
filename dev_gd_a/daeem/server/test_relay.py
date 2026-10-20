#!/usr/bin/env python3
"""Zero-dependency relay tests: handshake, rooms, forwarding, RFC6455 edges."""
from __future__ import annotations

import json
import subprocess
import sys
import threading
import time
import unittest
import urllib.request
from pathlib import Path

from relay_client import WSClient, WSClosed

HERE = Path(__file__).resolve().parent
RELAY = HERE / "daeem_relay.py"


def drain(stream) -> None:
    for _ in stream:
        pass


def make(t: str, seq: int, body: dict | None = None) -> dict:
    return {"v": 1, "t": t, "seq": seq, "ts": int(time.time() * 1000), "body": body or {}}


class RelayTests(unittest.TestCase):
    proc: subprocess.Popen
    port: int

    @classmethod
    def setUpClass(cls) -> None:
        cls.proc = subprocess.Popen(
            [sys.executable, str(RELAY), "--host", "127.0.0.1", "--port", "0"],
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            bufsize=1,
        )
        assert cls.proc.stdout is not None
        line = cls.proc.stdout.readline().strip()
        if not line.startswith("LISTEN "):
            raise RuntimeError(f"relay did not start: {line!r}")
        cls.port = int(line.rsplit(":", 1)[1])
        threading.Thread(target=drain, args=(cls.proc.stdout,), daemon=True).start()

    @classmethod
    def tearDownClass(cls) -> None:
        cls.proc.terminate()
        try:
            cls.proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            cls.proc.kill()

    def client(self) -> WSClient:
        return WSClient("127.0.0.1", self.port)

    def hello(self, c: WSClient, name: str = "tester") -> None:
        c.send_json(make("hello", 1, {"build": "coop-m13.1", "name": name}))
        msg = c.recv_json()
        self.assertEqual(msg.get("t"), "hello")

    def test_health(self) -> None:
        with urllib.request.urlopen(f"http://127.0.0.1:{self.port}/health", timeout=5) as r:
            body = json.loads(r.read().decode("utf-8"))
        self.assertTrue(body.get("ok"))
        self.assertIn("rooms", body)
        self.assertIn("players", body)
        self.assertIn("uptime", body)

    def test_room_forwarding(self) -> None:
        host = self.client()
        guest = self.client()
        self.hello(host, "host")
        self.hello(guest, "guest")

        host.send_json(make("create_room", 2, {"code": "123456", "name": "host"}))
        self.assertEqual(host.recv_json().get("t"), "room_state")
        guest.send_json(make("join_room", 2, {"code": "123456", "name": "guest"}))
        state = guest.recv_json()
        self.assertEqual(state.get("t"), "room_state")
        self.assertTrue(state["body"].get("host"))
        self.assertTrue(state["body"].get("guest"))

        # 2026.10.20：只有客机需要准备；主机按钮本身就是「开始」。
        guest.send_json(make("ready", 3, {"ready": True}))
        host.recv_until(lambda m: m.get("t") == "room_state" and m["body"].get("ready_guest"), 5)
        guest.recv_until(lambda m: m.get("t") == "room_state" and m["body"].get("ready_guest"), 5)

        host.send_json(make("start", 4, {"campaign": "demo", "level_id": "02_twin_line"}))
        start = guest.recv_until(lambda m: m.get("t") == "start", 5)
        self.assertEqual(start["body"].get("level_id"), "02_twin_line")

        guest.send_json(make("cmd", 5, {"by": "F2", "cmd": {"kind": "stop"}}))
        cmd = host.recv_until(lambda m: m.get("t") == "cmd", 5)
        self.assertEqual(cmd["body"]["cmd"]["kind"], "stop")

        host.send_json(make("snap", 6, {"snap": {"time": 1.0}}))
        snap = guest.recv_until(lambda m: m.get("t") == "snap", 5)
        self.assertEqual(snap["body"]["snap"]["time"], 1.0)

        # Guest leaves: host gets bye + room_state, room stays alive for the host.
        guest.send_json(make("bye", 7, {"reason": "guest_left"}))
        bye = host.recv_until(lambda m: m.get("t") == "bye", 5)
        self.assertEqual(bye["body"].get("reason"), "guest_left")
        host.recv_until(lambda m: m.get("t") == "room_state" and not m["body"].get("guest"), 5)
        host.send_json(make("bye", 8, {"reason": "host_left"}))
        host.close()
        guest.close()

    def test_fragmented_hello_and_length_126(self) -> None:
        c = self.client()
        raw = json.dumps(make("hello", 1, {"build": "coop-m13.1", "name": "frag"}))
        c.send_fragments([raw[:7], raw[7:19], raw[19:]])
        self.assertEqual(c.recv_json().get("t"), "hello")
        # >125 bytes but <65536: exercises the 126 length marker.
        c.send_json(make("create_room", 2, {"code": "654321", "name": "x" * 100}))
        self.assertEqual(c.recv_json().get("t"), "room_state")
        c.close()

    def test_length_127(self) -> None:
        c = self.client()
        self.hello(c)
        c.send_json(make("create_room", 2, {"code": "112233", "name": "x" * 70000}))
        self.assertEqual(c.recv_json().get("t"), "room_state")
        c.close()

    def test_unmasked_client_frame_is_rejected(self) -> None:
        c = self.client()
        raw = json.dumps(make("hello", 1, {"build": "coop-m13.1"}))
        c.send_text(raw, mask=False)
        msg = c.recv_json()
        self.assertEqual(msg.get("t"), "err")
        c.close()

    def test_close_is_echoed(self) -> None:
        c = self.client()
        self.hello(c)
        c.send_frame(0x8, (1000).to_bytes(2, "big") + b"bye")
        with self.assertRaises(WSClosed):
            c.recv_json()
        c.close()


if __name__ == "__main__":
    unittest.main(verbosity=2)

