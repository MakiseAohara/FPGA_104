r"""capture_proto7.py — 七阶段上板采集（与 evidence/v29_3/proto7 同一套流程）。

阶段（默认时长，可用 --scale 缩放）：
  0 PREP  25s  请离开画面
  1 EMPTY 60s  画面里没人没箱子
  2 PLACE 30s  进来把纸箱/书本放进画面然后离开
  3 BOX   60s  只有箱子书本，人不在
  4 STILL 60s  进画面站定面对镜头不动，30s 后低头
  5 SLOW  30s  慢慢走过画面
  6 EXIT  75s  走出画面并离开，保持不在

结束时算验收指标：
  - EMPTY 阶段 MMT_ALARM start 次数（要求 0）
  - STILL 阶段报警覆盖率（要求连续）
  - EXIT 阶段"最后一次 MMT_ALARM end"相对 EXIT 开始的延迟（要求 4–7 s）

用法：py -3 capture_proto7.py --out D:\cap7 [--scale 1.0] [--port COM15]
"""
import argparse, re, sys, time
from pathlib import Path
import serial

PHASES = [('PREP', 25, '请离开画面'), ('EMPTY', 60, '画面里没人没箱子'),
          ('PLACE', 30, '进来把纸箱书本放进画面然后离开'), ('BOX', 60, '只有箱子书本，人不在'),
          ('STILL', 60, '进画面站定面对镜头不动，30 秒后低头'), ('SLOW', 30, '慢慢走过画面'),
          ('EXIT', 75, '走出画面并离开，保持不在')]

ap = argparse.ArgumentParser()
ap.add_argument('--port', default='COM15')
ap.add_argument('--out', type=Path, required=True)
ap.add_argument('--scale', type=float, default=1.0)
a = ap.parse_args()
a.out.mkdir(parents=True, exist_ok=True)
log = (a.out / 'serial.log').open('w', encoding='utf-8', newline='\n')
buf = bytearray(); alarms = []; t_phase = {}

def lines_now(t_begin, t_end, name):
    return t_begin, t_end

with serial.Serial(a.port, 115200, timeout=0.05) as port:
    port.reset_input_buffer()
    for name, secs, hint in PHASES:
        t0 = time.monotonic()
        print(f'[{time.strftime("%H:%M:%S")}] PHASE {name} {int(secs*a.scale)}s — {hint}', flush=True)
        t_phase[name] = t0
        while time.monotonic() - t0 < secs * a.scale:
            chunk = port.read(max(1, port.in_waiting))
            if not chunk:
                continue
            buf.extend(chunk)
            while b'\n' in buf:
                line, tail = buf.split(b'\n', 1); buf[:] = tail
                text = line.decode('ascii', errors='replace').rstrip('\r')
                stamp = time.monotonic() - t0
                log.write(f'{name} {stamp:7.3f} {text}\n'); log.flush()
                if 'MMT_ALARM start' in text:
                    alarms.append((name, stamp, 'start', text))
                if 'MMT_ALARM end' in text:
                    alarms.append((name, stamp, 'end', text))

log.close()
by = {}
for name, stamp, kind, text in alarms:
    by.setdefault(name, []).append((stamp, kind))
print('\n=== 验收指标 ===')
print('EMPTY 报警次数 :', sum(1 for s, k in by.get('EMPTY', []) if k == 'start'))
print('STILL 报警次数 :', sum(1 for s, k in by.get('STILL', []) if k == 'start'))
ex = by.get('EXIT', [])
if ex:
    ends = [s for s, k in ex if k == 'end']
    print('EXIT 阶段报警结束相对 EXIT 起点 :', f'{max(ends):.2f} s' if ends else '无 end 事件')
else:
    print('EXIT 阶段: 无报警事件（人走后没有残留报警）')
