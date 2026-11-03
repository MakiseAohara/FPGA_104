#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""fake_board.py - 模拟板子按 UDP_EVENT_FORMAT v1 发包，用于 PC 端联调。
用法: py -3 tools/fake_board.py --host 127.0.0.1 --port 8080 --events 3 --hb 2
"""
import argparse, socket, struct, time, math, random

ap = argparse.ArgumentParser()
ap.add_argument("--host", default="127.0.0.1")
ap.add_argument("--port", type=int, default=8080)
ap.add_argument("--events", type=int, default=3)
ap.add_argument("--hb", type=int, default=2)
a = ap.parse_args()
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)

def pkt(ptype, eid, seq, total, payload, ms=None):
    ms = int(time.time() * 1000) & 0xFFFFFFFF if ms is None else ms
    return bytes([0x4D, 0x54, 1, ptype]) + struct.pack(">IHHI", eid, seq, total, ms) + payload

def thumb(eid, cx, cy):
    buf = bytearray(96 * 96)
    for y in range(96):
        for x in range(96):
            d = math.hypot(x - cx, y - cy)
            v = 200 - min(150, d * 3) + random.randint(-6, 6)
            buf[y * 96 + x] = int(max(0, min(255, v)))
    for i in range(0, 9216, 1000):
        part = bytes(buf[i:i + 1000])
        s.sendto(pkt(3, eid, i // 1000 + 1, 10, part), (a.host, a.port))
        time.sleep(0.002)

for k in range(a.hb):
    s.sendto(pkt(2, 0, 0, 1, b""), (a.host, a.port)); time.sleep(0.3)
for e in range(a.events):
    eid = 100 + e
    cx, cy = random.randint(20, 76), random.randint(20, 76)
    body = bytes([1, cx, cy, 70 + e, min(3, e)])          # INTRUDE
    s.sendto(pkt(1, eid, 0, 1, body), (a.host, a.port))
    time.sleep(0.05)
    thumb(eid, cx, cy)
    time.sleep(0.05)
    s.sendto(pkt(1, eid, 0, 1, bytes([0, cx, cy, 60, 0])), (a.host, a.port))  # NORMAL
print("sent %d events / %d hb" % (a.events, a.hb))
