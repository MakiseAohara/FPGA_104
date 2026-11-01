# -*- coding: utf-8 -*-
"""第二轮评估：int8 tflite 在 v29_scene F / 白天验证段 / COCO 验证上的指标"""
import argparse, csv, json, os, re, sys
import numpy as np
import tensorflow as tf
from PIL import Image
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from decode_scene_log import parse_log


def load_it(p):
    it = tf.lite.Interpreter(model_path=p); it.allocate_tensors(); return it


def infer(it, imgs):
    ind = it.get_input_details()[0]; outd = it.get_output_details()[0]
    osc, ozp = outd['quantization']
    qs, ps = [], []
    for u in imgs:
        q = np.clip(u.astype(np.int16) - 128, -128, 127).astype(np.int8)
        it.set_tensor(ind['index'], q[None, :, :, None]); it.invoke()
        o = it.get_tensor(outd['index'])[0]
        qs.append(int(o[1])); ps.append((float(o[1]) - ozp) * osc)
    return np.array(qs), np.array(ps)


def auc(s, y):
    o = np.argsort(-s); ys = y[o]
    tpr = np.cumsum(ys) / max(ys.sum(), 1); fpr = np.cumsum(1 - ys) / max((1 - ys).sum(), 1)
    return float(np.trapz(tpr, fpr))


def metrics(q, p, y):
    pos = q[y == 1]; neg = q[y == 0]
    return {'n': int(len(y)), 'pos_n': int(len(pos)), 'neg_n': int(len(neg)),
            'pos_med_q': int(np.median(pos)) if len(pos) else None,
            'neg_med_q': int(np.median(neg)) if len(neg) else None,
            'pos_max_q': int(pos.max()) if len(pos) else None,
            'neg_max_q': int(neg.max()) if len(neg) else None,
            'acc@q0': float(((q >= 0).astype(int) == y).mean()),
            'auc': auc(p, y) if len(set(y)) > 1 else None}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--tflite', required=True)
    ap.add_argument('--log', required=True)
    ap.add_argument('--labels', required=True)
    ap.add_argument('--day-labels', required=True)
    ap.add_argument('--coco', required=True)
    ap.add_argument('--out', required=True)
    a = ap.parse_args()
    it = load_it(a.tflite)
    res = {}

    # v29_scene F 段
    frames = parse_log(a.log)
    by_key = {(f['stage'], f['t']): f for f in frames}
    fx, fy = [], []
    for r in csv.DictReader(open(a.labels, encoding='utf-8')):
        if r['label_intruder'] == '-1':
            continue
        m = re.match(r'([A-F])_t(\d+)_p(-?\d+)\.png', r['file'])
        if not m or m.group(1) != 'F':
            continue
        f = by_key.get((m.group(1), int(m.group(2))))
        if f is not None:
            fx.append(f['pixels']); fy.append(int(r['label_intruder']))
    q, p = infer(it, fx)
    res['v29_scene_F'] = metrics(q, np.array(p), np.array(fy))

    # 白天验证段
    base = os.path.dirname(a.day_labels)
    vx, vy = [], []
    for r in csv.DictReader(open(a.day_labels, encoding='utf-8')):
        if r['label_intruder'] not in ('0', '1'):
            continue
        if r['wall'] < '2026-10-28T15:13:00':
            continue
        u = np.asarray(Image.open(os.path.join(base, r['file'])).convert('L'), dtype=np.uint8)
        vx.append(u); vy.append(int(r['label_intruder']))
    q, p = infer(it, vx)
    res['day_val'] = metrics(q, np.array(p), np.array(vy))

    # COCO 验证（3000 张）
    xcv = np.load(os.path.join(a.coco, 'val_x.npy')); ycv = np.load(os.path.join(a.coco, 'val_y.npy'))
    idx = np.random.RandomState(0).choice(len(xcv), min(3000, len(xcv)), replace=False)
    q, p = infer(it, xcv[idx])
    res['coco_val'] = metrics(q, np.array(p), ycv[idx])

    os.makedirs(os.path.dirname(a.out), exist_ok=True)
    json.dump(res, open(a.out, 'w'), indent=2, ensure_ascii=False, default=int)
    print(json.dumps(res, indent=2, ensure_ascii=False, default=int))


if __name__ == '__main__':
    main()
