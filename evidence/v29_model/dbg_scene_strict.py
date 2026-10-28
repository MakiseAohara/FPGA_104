# -*- coding: utf-8 -*-
"""检查 A/B 段 p 与 q 的分布，并测试「帧号连续性」过滤后的自检相关"""
import sys, os, re, csv
import numpy as np
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from decode_scene_log import load_old_model, infer_old, RE_STAT, RE_IMG

LOG = r'D:\FPGA\易灵思\工作区\_外部仓库\FPGA_104\evidence\v29_scene\log_v29_scene.log'
MODEL = r'D:\FPGA\mmt\work_v29\out\old_person_detect_fixed.tflite'
LABELS = r'D:\FPGA\mmt\comms\scene_labels_v29\labels_v29_scene.csv'


def parse_strict(path):
    """严格模式：帧号 f 必须连续，否则丢弃当前组；输出完整 96 行才成帧"""
    frames = []
    cur, rows, prev_f = None, {}, None
    dropped = 0
    with open(path, 'r', encoding='utf-8', errors='replace') as fh:
        for raw in fh:
            s = raw.split('\t', 1)[-1].strip()
            m = RE_STAT.search(s)
            if m:
                fno = int(m.group(1))
                if cur is not None and rows:
                    dropped += 1
                if prev_f is not None and fno != prev_f + 1:
                    dropped += 1
                cur = dict(f=fno, p=int(m.group(5)), stage=m.group(6), t=int(m.group(7)),
                           mean_sensor=int(m.group(8)))
                rows = {}
                prev_f = fno
                continue
            m = RE_IMG.search(s)
            if m and cur is not None:
                rows[int(m.group(1))] = bytes.fromhex(m.group(2))
                if len(rows) == 96:
                    a = np.zeros((96, 96), np.uint8)
                    for k in range(96):
                        a[k, :] = np.frombuffer(rows[k], np.uint8)
                    frames.append(dict(cur, pixels=a))
                    cur, rows = None, {}
    return frames, dropped


frames, dropped = parse_strict(LOG)
print('strict frames:', len(frames), 'dropped groups:', dropped)
by_key = {(f['stage'], f['t']): f for f in frames}
rows = list(csv.DictReader(open(LABELS, encoding='utf-8')))
pairs = []
for r in rows:
    m = re.match(r'([A-F])_t(\d+)_p(-?\d+)\.png', r['file'])
    if not m: continue
    f = by_key.get((m.group(1), int(m.group(2))))
    if f: pairs.append((r, f))
print('matched:', len(pairs))
it = load_old_model(MODEL)
q = infer_old(it, [f['pixels'] for _, f in pairs])
p = np.array([f['p'] for _, f in pairs])
d = q - p
print('ALL corr=%.4f mean|d|=%.2f frac<=2=%.3f' % (np.corrcoef(q, p)[0, 1], np.abs(d).mean(), (np.abs(d) <= 2).mean()))
for s in 'ABCDEF':
    m = np.array([f['stage'] == s for _, f in pairs])
    if m.sum():
        print('seg %s n=%d corr=%.4f mean|d|=%.2f p[min,max]=[%d,%d] q[min,max]=[%d,%d]' % (
            s, m.sum(), np.corrcoef(q[m], p[m])[0, 1], np.abs(d[m]).mean(),
            p[m].min(), p[m].max(), q[m].min(), q[m].max()))
# 只统计 D/E/F（训练/验证相关段）
m = np.array([f['stage'] in 'DEF' for _, f in pairs])
print('DEF corr=%.4f frac<=2=%.3f' % (np.corrcoef(q[m], p[m])[0, 1], (np.abs(d[m]) <= 2).mean()))
