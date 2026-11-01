# -*- coding: utf-8 -*-
"""统计白天标签集：标签分布、wall 分段、图片规格"""
import csv, collections, os, sys
from PIL import Image

d = r'D:\FPGA\mmt\comms\scene_labels_v29_day'
rows = list(csv.DictReader(open(os.path.join(d, 'labels_v29_day.csv'), encoding='utf-8')))
print('rows', len(rows))
print('label distribution', collections.Counter(r['label_intruder'] for r in rows))
# wall 时间
split = [r for r in rows if r['wall'] >= '2026-10-28T15:13:00']
train = [r for r in rows if r['wall'] < '2026-10-28T15:13:00']
print('val (wall>=15:13:00):', len(split), ' labels', collections.Counter(r['label_intruder'] for r in split))
print('train(wall< 15:13:00):', len(train), ' labels', collections.Counter(r['label_intruder'] for r in train))
# 用 valid 标签
val = [r for r in split if r['label_intruder'] in ('0', '1')]
tr = [r for r in train if r['label_intruder'] in ('0', '1')]
print('val usable:', len(val), collections.Counter(r['label_intruder'] for r in val))
print('train usable:', len(tr), collections.Counter(r['label_intruder'] for r in tr))
# 图片规格
sizes = collections.Counter()
for r in rows[:20]:
    p = os.path.join(d, r['file'])
    if os.path.exists(p):
        im = Image.open(p)
        sizes[im.size] += 1
print('sizes(first 20)', sizes)
# 时间范围
print('wall min/max', min(r['wall'] for r in rows), max(r['wall'] for r in rows))
