# -*- coding: utf-8 -*-
"""diag_two_target.py — C 段（两人同时）诊断：
逐帧统计检测数 nd、确认航迹数 conf、最大连通域面积 area/raw，
把"只有 1 个检测"的帧分成：
  A. 两人连成一块（area 明显大于单人典型面积，>1.6×）
  B. 第二人被最小面积/碎片规则丢掉（area 与单人相当）
输出比例，供决定是否做连通域分裂。
用法: python diag_two_target.py <log> [--single-area 480]
"""
import argparse, re, statistics
from pathlib import Path

ap = argparse.ArgumentParser()
ap.add_argument('log')
ap.add_argument('--single-area', type=int, default=480, help='单人典型检测面积（px，默认按 24x20）')
a = ap.parse_args()

PHASE = re.compile(r'^(READY|A0|A\d+|B1|B2|B3|C\d+|D|E)\s+(\d+\.\d+)\s*(.*)')
MOT = re.compile(r'MMT_MOT f=(\d+) nd=(\d+) nt=(\d+) conf=(\d+) area=(\d+) raw=(\d+)')

cur = None
frames = []
for line in open(a.log, encoding='utf-8', errors='replace'):
    m = PHASE.match(line)
    if m:
        cur = m.group(1)
        continue
    mm = MOT.search(line)
    if mm and cur:
        frames.append(dict(step=cur, f=int(mm.group(1)), nd=int(mm.group(2)),
                           nt=int(mm.group(3)), conf=int(mm.group(4)),
                           area=int(mm.group(5)), raw=int(mm.group(6))))

c_frames = [x for x in frames if x['step'].startswith('C')]
if not c_frames:
    print('C 段帧数 0（日志里没有 C1/C2 阶段标记或无 MMT_MOT 行）')
    raise SystemExit(0)

one_det = [x for x in c_frames if x['nd'] <= 1]
two_det = [x for x in c_frames if x['nd'] >= 2]
big = [x for x in one_det if x['area'] > a.single_area * 1.6]
small = [x for x in one_det if x['area'] <= a.single_area * 1.6]
areas = [x['area'] for x in c_frames if x['nd'] >= 2]
n = len(c_frames)

print('C 段帧数 %d' % n)
print('  nd>=2（两人分开检出）: %d (%.1f%%)' % (len(two_det), len(two_det) * 100.0 / n))
print('  nd<=1（只检出 1 个）  : %d (%.1f%%)' % (len(one_det), len(one_det) * 100.0 / n))
print('    其中 A 两人连成一块（area > 1.6x %d）: %d (%.1f%% of nd<=1)'
      % (a.single_area, len(big), len(big) * 100.0 / max(1, len(one_det))))
print('    其中 B 第二人被丢（area 与单人相当）  : %d (%.1f%% of nd<=1)'
      % (len(small), len(small) * 100.0 / max(1, len(one_det))))
if areas:
    print('  两人分开时的检测面积 中位/p90: %d / %d'
          % (int(statistics.median(areas)), sorted(areas)[int(len(areas) * 0.9)]))
print('  确认航迹数分布:', dict(sorted(((k, sum(1 for x in c_frames if x['conf'] == k))
                                     for k in set(x['conf'] for x in c_frames)))))
