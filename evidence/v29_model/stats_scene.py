# -*- coding: utf-8 -*-
"""统计 v29_scene 标签（按段 / label_intruder）"""
import csv, collections, os, sys

p = sys.argv[1] if len(sys.argv) > 1 else r'D:\FPGA\mmt\comms\scene_labels_v29\labels_v29_scene.csv'
rows = list(csv.DictReader(open(p, encoding='utf-8')))
print('rows', len(rows), 'cols', rows[0].keys() if rows else None)
seg = collections.Counter(r['segment'] for r in rows)
print('segments', dict(seg))
for s in sorted(seg):
    sub = [r for r in rows if r['segment'] == s]
    lab = collections.Counter(r['label_intruder'] for r in sub)
    print('  seg', s, 'n=%d' % len(sub), 'labels', dict(lab))
allab = collections.Counter(r['label_intruder'] for r in rows)
print('all labels', dict(allab))
pos = [int(r['q_new']) for r in rows if r['label_intruder'] == '1' and r['segment'] in ('D', 'E', 'F')]
neg = [int(r['q_new']) for r in rows if r['label_intruder'] == '0' and r['segment'] in ('D', 'E', 'F')]
print('D/E/F pos n=%d median=%s ; neg n=%d median=%s' % (
    len(pos), sorted(pos)[len(pos)//2] if pos else None, len(neg), sorted(neg)[len(neg)//2] if neg else None))
