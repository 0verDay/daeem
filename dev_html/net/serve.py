#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
net/serve.py —— RTS 原型联机服务器（房主权威 + 中继）

设计目标（刻意做小）：
  · **零第三方依赖**：只用 Python 标准库。WebSocket 握手与帧解析自己实现（约 150 行）。
  · **不碰游戏规则**：服务器不 import 任何游戏模块，只转发字节。
    这样就不需要把 main.js 拆成 DOM 层与逻辑层（Node 里没有 document），
    也不会出现「服务端规则与客户端规则不一致」这类最难查的 bug。
  · **退无可退也别白屏**：连不上服务器时，前端会自动退回单机模式（见 js/net.js）。

职责只有四件事：
  1. 静态托管 dev_html 目录（这样浏览器用 http:// 打开，ES Module 才能加载）
  2. WebSocket 握手 + 帧收发
  3. 内存房间表（每个房间第一个进来的是房主）
  4. 转发：
       · 非房主发来的 cmd  → 只发给房主
       · 房主发来的 snap   → 广播给房间里其他人

用法：
  python net/serve.py                    # 默认 0.0.0.0:8080
  python net/serve.py --port 8080
  python net/serve.py --root dev_html    # 静态根目录（默认自动推断）
  python net/serve.py --verbose          # 打印每条消息

客户端：
  http://<服务器IP>:8080/rts-prototype.html#net=1         第一个打开的人是房主
  http://<服务器IP>:8080/rts-prototype.html#net=1&room=a  指定房间（默认 default）
"""

import argparse
import base64
import hashlib
import json
import os
import socket
import struct
import sys
import threading
import time
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer

GUID = '258EAFA5-E914-47DA-95CA-C5AB0DC85B11'   # RFC 6455 固定常量
HERE = os.path.dirname(os.path.abspath(__file__))
ROOT_DEFAULT = os.path.dirname(HERE)             # dev_html/

# 玩家席位：第 1 个进房间的是 p1（房主），第 2 个是 p2，以此类推
ROSTER = ['p1', 'p2', 'p3', 'p4', 'p5', 'p6', 'p7', 'p8']

# 帧长度上限。快照约 2KB，给足余量；防止畸形包把内存打满。
MAX_FRAME = 4 * 1024 * 1024


def now_ms():
    return int(time.time() * 1000)


# ----------------------------------------------------------------------
# WebSocket 帧编解码（只实现联机测试需要的部分）
# ----------------------------------------------------------------------

OP_CONT, OP_TEXT, OP_BIN, OP_CLOSE, OP_PING, OP_PONG = 0x0, 0x1, 0x2, 0x8, 0x9, 0xA


class WSError(Exception):
    pass


def recv_exactly(sock, n):
    """从 socket 精确读取 n 字节；对端关闭时抛 WSError。"""
    buf = bytearray()
    while len(buf) < n:
        chunk = sock.recv(n - len(buf))
        if not chunk:
            raise WSError('peer closed')
        buf += chunk
    return bytes(buf)


def read_frame(sock):
    """
    读一个完整的 WebSocket 帧，返回 (opcode, payload)。

    ★ 支持分片（continuation）：浏览器在消息较大时会分片发送。
      对端关闭返回 (None, None) 而不是抛异常。
    """
    data = bytearray()
    msg_op = None

    while True:
        b1, b2 = recv_exactly(sock, 2)
        fin = b1 & 0x80
        opcode = b1 & 0x0F
        masked = b2 & 0x80
        length = b2 & 0x7F

        if length == 126:
            length = struct.unpack('>H', recv_exactly(sock, 2))[0]
        elif length == 127:
            length = struct.unpack('>Q', recv_exactly(sock, 8))[0]
        if length > MAX_FRAME:
            raise WSError('frame too large: %d' % length)

        mask = recv_exactly(sock, 4) if masked else None
        payload = recv_exactly(sock, length) if length else b''
        if mask:
            payload = bytes(payload[i] ^ mask[i % 4] for i in range(len(payload)))

        if opcode == OP_CLOSE:
            return None, None
        if opcode == OP_PING:
            send_frame(sock, OP_PONG, payload)
            continue
        if opcode == OP_PONG:
            continue

        if opcode == OP_CONT:
            if msg_op is None:
                raise WSError('continuation without start')
            data += payload
        else:
            msg_op = opcode
            data = bytearray(payload)

        if fin:
            return msg_op, bytes(data)


def send_frame(sock, opcode, payload=b''):
    """发一个帧（服务器 → 客户端，按 RFC 不掩码）。"""
    if isinstance(payload, str):
        payload = payload.encode('utf-8')
    header = bytearray([0x80 | opcode])
    n = len(payload)
    if n < 126:
        header.append(n)
    elif n < 65536:
        header.append(126)
        header += struct.pack('>H', n)
    else:
        header.append(127)
        header += struct.pack('>Q', n)
        # 客户端不掩码时长度不带掩码位
    sock.sendall(bytes(header) + payload)


def send_json(peer, obj):
    send_frame(peer.sock, OP_TEXT, json.dumps(obj, separators=(',', ':')))


# ----------------------------------------------------------------------
# 房间与连接
# ----------------------------------------------------------------------

class Peer:
    """一个已连接的浏览器。"""

    def __init__(self, sock, addr, pid):
        self.sock = sock
        self.addr = addr
        self.id = pid
        self.room = None
        self.faction = None
        self.is_host = False
        self.alive = True
        self.lock = threading.Lock()   # 同一连接不能被两个线程同时写

    def send(self, obj):
        if not self.alive:
            return
        try:
            with self.lock:
                send_json(self, obj)
        except Exception:
            self.alive = False

    def close(self):
        self.alive = False
        try:
            self.sock.shutdown(socket.SHUT_RDWR)
        except Exception:
            pass
        try:
            self.sock.close()
        except Exception:
            pass


class Room:
    def __init__(self, name):
        self.name = name
        self.peers = []
        self.lock = threading.Lock()

    def host(self):
        for p in self.peers:
            if p.is_host:
                return p
        return None

    def roster(self):
        """房间内所有玩家阵营（房主在前），用于区块/资源的多方归属"""
        return [p.faction for p in self.peers if p.faction]


ROOMS = {}
ROOMS_LOCK = threading.Lock()
PEER_SEQ = [0]
VERBOSE = False


def vlog(*a):
    if VERBOSE:
        print(*a, flush=True)


def log(*a):
    print('[%s]' % time.strftime('%H:%M:%S'), *a, flush=True)


def get_room(name):
    with ROOMS_LOCK:
        r = ROOMS.get(name)
        if r is None:
            r = Room(name)
            ROOMS[name] = r
        return r


def join_room(peer, name):
    room = get_room(name)
    with room.lock:
        # 先到的是房主；房主掉线后由下一位接任（简单选举，够测试用）
        peer.is_host = room.host() is None
        used = {p.faction for p in room.peers}
        if peer.is_host:
            peer.faction = ROSTER[0]
        else:
            peer.faction = next((f for f in ROSTER if f not in used), None)
            if peer.faction is None:
                peer.send({'t': 'error', 'msg': '房间已满（最多 %d 人）' % len(ROSTER)})
                return False
        peer.room = name
        room.peers.append(peer)
        peers_n = len(room.peers)
        roster = room.roster()

    peer.send({
        't': 'welcome',
        'id': peer.id,
        'isHost': peer.is_host,
        'faction': peer.faction,
        'roster': roster,
        'peers': peers_n,
    })
    broadcast(room, {'t': 'peer', 'event': 'join', 'id': peer.id, 'peers': peers_n}, skip=peer)
    log('room=%s  %s 加入  阵营=%s  %s  人数=%d'
        % (name, peer.id, peer.faction, '房主' if peer.is_host else '客机', peers_n))
    return True


def leave_room(peer):
    if not peer.room:
        return
    room = get_room(peer.room)
    with room.lock:
        if peer in room.peers:
            room.peers.remove(peer)
        peers_n = len(room.peers)
        # 房主走了：把房主让给还在的第一个人，否则这局没人跑逻辑了
        promoted = None
        if peer.is_host and room.peers and room.host() is None:
            promoted = room.peers[0]
            promoted.is_host = True
        if not room.peers:
            with ROOMS_LOCK:
                ROOMS.pop(room.name, None)
    broadcast(room, {'t': 'peer', 'event': 'leave', 'id': peer.id, 'peers': peers_n})
    if promoted:
        promoted.send({
            't': 'welcome', 'id': promoted.id, 'isHost': True,
            'faction': promoted.faction, 'roster': room.roster(), 'peers': peers_n,
        })
        log('room=%s  房主掉线 → %s 接任' % (room.name, promoted.id))
    log('room=%s  %s 离开  人数=%d' % (room.name, peer.id, peers_n))


def broadcast(room, obj, skip=None):
    with room.lock:
        targets = [p for p in room.peers if p is not skip]
    for p in targets:
        p.send(obj)


def route(peer, msg):
    """
    ★ 全部中继逻辑就这四条规则。

    1. cmd    ：客户端 → 服务器 → **只发给房主**（房主手里有唯一的权威 state）
    2. snap   ：房主 → 服务器 → **广播给其他所有人**
    3. ready  ：任意客户端 → 服务器 → **广播给房间里所有人**（准备界面用）
    4. start  ：房主 → 服务器 → **广播给其他所有人**（倒计时结束、正式开打）
    """
    t = msg.get('t')
    room = get_room(peer.room) if peer.room else None
    if room is None:
        return

    if t == 'cmd':
        host = room.host()
        if host and host is not peer:
            msg['from'] = peer.id
            msg['f'] = peer.faction        # ★ 阵营由服务器盖章，防止客机冒充别人
            host.send(msg)
        vlog('  cmd %s → 房主  kind=%s' % (peer.id, msg.get('kind')))

    elif t == 'snap':
        if not peer.is_host:
            return                          # 客机不许广播快照
        with room.lock:
            targets = [p for p in room.peers if p is not peer]
        for p in targets:
            p.send(msg)
        vlog('  snap 房主 → %d 人' % len(targets))

    elif t == 'ready':
        # 准备状态：带上服务器盖章的阵营，客户端不必信任对端自称
        msg['from'] = peer.id
        msg['f'] = peer.faction
        with room.lock:
            targets = list(room.peers)
        for p in targets:
            p.send(msg)
        vlog('  ready %s faction=%s ready=%s' % (peer.id, peer.faction, msg.get('ready')))

    elif t == 'start':
        if not peer.is_host:
            return                          # 只有房主能宣布开打
        with room.lock:
            targets = [p for p in room.peers if p is not peer]
        for p in targets:
            p.send(msg)
        vlog('  start 房主 → %d 人' % len(targets))


# ----------------------------------------------------------------------
# HTTP + WebSocket 升级
# ----------------------------------------------------------------------

class Handler(SimpleHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'

    def log_message(self, fmt, *args):
        if VERBOSE:
            SimpleHTTPRequestHandler.log_message(self, fmt, *args)

    def do_GET(self):
        path = self.path.split('?', 1)[0]

        if path == '/health':
            body = json.dumps({
                'ok': True,
                'time': now_ms(),
                'rooms': len(ROOMS),
                'peers': sum(len(r.peers) for r in ROOMS.values()),
            }).encode('utf-8')
            self.send_response(200)
            self.send_header('Content-Type', 'application/json; charset=utf-8')
            self.send_header('Content-Length', str(len(body)))
            self.send_header('Access-Control-Allow-Origin', '*')
            self.end_headers()
            self.wfile.write(body)
            return

        if path == '/ws':
            self.handle_ws()
            return

        if path == '/':
            self.path = '/rts-prototype.html'
        return SimpleHTTPRequestHandler.do_GET(self)

    def end_headers(self):
        # 测试期禁用缓存，省得「改了代码但浏览器还是旧的」这种时间黑洞
        self.send_header('Cache-Control', 'no-store')
        SimpleHTTPRequestHandler.end_headers(self)

    def handle_ws(self):
        key = self.headers.get('Sec-WebSocket-Key')
        if not key or 'websocket' not in (self.headers.get('Upgrade') or '').lower():
            self.send_error(400, 'expected websocket upgrade')
            return

        accept = base64.b64encode(hashlib.sha1((key + GUID).encode()).digest()).decode()
        self.wfile.write((
            'HTTP/1.1 101 Switching Protocols\r\n'
            'Upgrade: websocket\r\n'
            'Connection: Upgrade\r\n'
            'Sec-WebSocket-Accept: %s\r\n\r\n' % accept
        ).encode())
        self.wfile.flush()

        sock = self.connection
        sock.settimeout(None)
        with ROOMS_LOCK:
            PEER_SEQ[0] += 1
            pid = 'c%d' % PEER_SEQ[0]
        peer = Peer(sock, self.client_address, pid)

        try:
            while peer.alive:
                op, payload = read_frame(sock)
                if op is None:
                    break
                if op != OP_TEXT:
                    continue
                try:
                    msg = json.loads(payload.decode('utf-8'))
                except Exception:
                    continue

                if msg.get('t') == 'hello':
                    if peer.room is None:
                        join_room(peer, str(msg.get('room') or 'default')[:32])
                    continue

                if peer.room is None:
                    continue      # 还没 hello 就想发游戏消息 → 忽略
                route(peer, msg)
        except (WSError, OSError):
            pass
        except Exception as e:
            log('连接异常 %s: %r' % (peer.id, e))
        finally:
            leave_room(peer)
            peer.close()
            self.close_connection = True


def main():
    global VERBOSE
    ap = argparse.ArgumentParser()
    ap.add_argument('--host', default='0.0.0.0', help='监听地址（默认 0.0.0.0，外网要访问就必须是它）')
    ap.add_argument('--port', type=int, default=8080)
    ap.add_argument('--root', default=ROOT_DEFAULT, help='静态根目录（默认 dev_html）')
    ap.add_argument('--verbose', action='store_true')
    args = ap.parse_args()

    VERBOSE = args.verbose
    root = os.path.abspath(args.root)
    if not os.path.isdir(root):
        print('静态根目录不存在：%s' % root, file=sys.stderr)
        return 2

    os.chdir(root)
    if not os.path.exists(os.path.join(root, 'rts-prototype.html')):
        print('提示：%s 下没有 rts-prototype.html，先跑 tools/build_single_file.py' % root)

    httpd = ThreadingHTTPServer((args.host, args.port), Handler)
    httpd.daemon_threads = True

    print('=' * 62)
    print(' RTS 联机测试服务器（房主权威 + 中继，零第三方依赖）')
    print('=' * 62)
    print(' 静态根目录 : %s' % root)
    print(' 监听       : %s:%d' % (args.host, args.port))
    print(' 健康检查   : http://<本机IP>:%d/health' % args.port)
    print(' 房主打开   : http://<本机IP>:%d/rts-prototype.html#net=1' % args.port)
    print(' 客机打开   : http://<本机IP>:%d/rts-prototype.html#net=1&room=default' % args.port)
    print('-' * 62)
    print(' 连不上先查这两处：')
    print('   1) 腾讯云控制台 → 安全组 → 入站规则 → TCP:%d' % args.port)
    print('   2) Windows 防火墙 → 入站规则 → 允许 TCP:%d' % args.port)
    print('=' * 62)
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        print('\n已停止')
    return 0


if __name__ == '__main__':
    sys.exit(main())
