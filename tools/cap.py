#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""cap.py - 被动采集串口到文件（不抢 http 服务），用于离线指标对比。
用法: py -3 tools/cap.py --port COM15 --secs 90 --out out/runA
"""
import argparse, time
from pathlib import Path
import serial

ap = argparse.ArgumentParser()
ap.add_argument("--port", default="COM15")
ap.add_argument("--secs", type=int, default=90)
ap.add_argument("--out", type=Path, default=Path("out/cap"))
a = ap.parse_args()
a.out.mkdir(parents=True, exist_ok=True)
log = (a.out / "serial.log").open("w", encoding="utf-8", buffering=1)
t0 = time.time(); n = 0
with serial.Serial(a.port, 115200, timeout=0.2) as p:
    p.reset_input_buffer()
    buf = bytearray()
    while time.time() - t0 < a.secs:
        chunk = p.read(max(1, p.in_waiting))
        if not chunk:
            continue
        buf.extend(chunk)
        while b"\n" in buf:
            line, tail = buf.split(b"\n", 1)
            buf[:] = tail
            log.write(line.decode("ascii", errors="replace").rstrip("\r") + "\n"); n += 1
print("captured %d lines -> %s" % (n, a.out / "serial.log"))
