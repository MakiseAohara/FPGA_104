#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""capture_pred.py - 预测功能验收采集（单人可做，约 4 分钟）

流程（每一步都会响提示音 + 屏幕大字）：
  READY  15 s  人离开画面（空场基线：这段里不能有任何预警）
  STAND  20 s  站到画面中间不要动（站定：也不能有预警）
  APP1..5 每轮 12 s：先退出画面 4 s，再朝镜头走过来，走到约 1.5 m 停下 4 s
               （每轮应该出现 1 次 MMT_PREWARN，随后报警；停下后 pre_eta 消失）
  LEAVE  20 s  走出画面（报警应解除，且不再预警）

采集完自动跑 tools/pred_accept.py 出判定。
用法: py -3 tools/capture_pred.py --port COM15 --out out/pred_A [--scale 1.0]
"""
import argparse, subprocess, sys, time
from pathlib import Path
import serial
try:
    import winsound
except Exception:
    winsound = None

STEPS = []
def add(name, secs, prompt):
    STEPS.append((name, secs, prompt))

add("READY", 15, "人离开画面，空场 15 秒（这段不允许有任何预警）")
add("STAND", 20, "站到画面中间，正面朝镜头，不要动 20 秒（站定也不允许预警）")
for i in range(1, 6):
    add("APP%d" % i, 12, "第 %d/5 次：先退出画面 4 秒 → 再朝镜头走过来 → 到约 1.5 m 停下 4 秒" % i)
add("LEAVE", 20, "走出画面，空场 20 秒（报警应解除）")

ap = argparse.ArgumentParser()
ap.add_argument("--port", default="COM15")
ap.add_argument("--out", type=Path, default=Path("out/pred_A"))
ap.add_argument("--scale", type=float, default=1.0, help="时间缩放，仅用于快速自检")
ap.add_argument("--baud", type=int, default=115200)
a = ap.parse_args()
a.out.mkdir(parents=True, exist_ok=True)

def beep(n=1, freq=880):
    if winsound is None:
        return
    for _ in range(n):
        winsound.Beep(freq, 120); time.sleep(0.05)

log = (a.out / "serial.log").open("w", encoding="utf-8", buffering=1)
print("=" * 70)
print("预测验收采集：%d 步，总时长约 %.0f 秒" % (len(STEPS), sum(s for _, s, _ in STEPS) * a.scale))
print("=" * 70)
beep(3, 1200)
time.sleep(1)

with serial.Serial(a.port, a.baud, timeout=0.05) as port:
    port.reset_input_buffer()
    buf = bytearray()
    for name, secs, prompt in STEPS:
        dur = max(2.0, secs * a.scale)
        print("\n[%s] %s  (%.0f s)" % (name, prompt, dur), flush=True)
        beep(2, 1400)
        log.write("# STEP %s %.0f s\n" % (name, dur))
        t0 = time.time()
        while time.time() - t0 < dur:
            chunk = port.read(max(1, port.in_waiting))
            if chunk:
                buf.extend(chunk)
                while b"\n" in buf:
                    line, tail = buf.split(b"\n", 1)
                    buf[:] = tail
                    log.write(line.decode("ascii", errors="replace").rstrip("\r") + "\n")
            if time.time() - t0 > dur - 1.5:
                beep(1, 600)          # 结束前 1.5 s 提醒
                time.sleep(0.3)
log.close()
print("\n采集完成 ->", a.out / "serial.log")
print("-" * 70)

# 若刚采的是空场（板子空转），也能跑出 "数据不足"，不会崩
try:
    subprocess.run([sys.executable, str(Path(__file__).with_name("pred_accept.py")),
                    str(a.out / "serial.log"), "--json", str(a.out / "accept.json")], check=False)
except Exception as e:
    print("pred_accept 运行失败:", e)
