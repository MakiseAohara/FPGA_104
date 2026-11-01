# -*- coding: utf-8 -*-
"""评估（日志解码版）：v29_scene D/E/F 段 + COCO 验证，板上口径 u-128"""
import argparse, csv, json, os, re, sys
import numpy as np
import tensorflow as tf
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from decode_scene_log import parse_log


def load(p):
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


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--tflite', required=True)
    ap.add_argument('--log', required=True)
    ap.add_argument('--labels', required=True)
    ap.add_argument('--coco', required=True)
    ap.add_argument('--out', required=True)
    a = ap.parse_args()
    frames = parse_log(a.log)
    by_key = {(f['stage'], f['t']): f for f in frames}
    rows = []
    for r in csv.DictReader(open(a.labels, encoding='utf-8')):
        if r['label_intruder'] == '-1':
            continue
        m = re.match(r'([A-F])_t(\d+)_p(-?\d+)\.png', r['file'])
        if not m:
            continue
        f = by_key.get((m.group(1), int(m.group(2))))
        if f is not None:
            rows.append((f['stage'], int(r['label_intruder']), f['pixels']))
    it = load(a.tflite)
    res = {}
    allq, ally, allp = [], [], []
    for seg in ('D', 'E', 'F'):
        sub = [(y, px) for s, y, px in rows if s == seg]
        if not sub:
            continue
        q, pr = infer(it, [px for _, px in sub])
        y = np.array([yy for yy, _ in sub])
        res[seg] = {'n': int(len(y)), 'pos_n': int((y == 1).sum()), 'neg_n': int((y == 0).sum()),
                    'pos_med_q': int(np.median(q[y == 1])), 'neg_med_q': int(np.median(q[y == 0])),
                    'acc@q>=0': float(((q >= 0).astype(int) == y).mean()),
                    'auc': auc(pr, y) if len(set(y)) > 1 else None}
        allq.append(q); ally.append(y); allp.append(pr)
    q = np.concatenate(allq); y = np.concatenate(ally); pr = np.concatenate(allp)
    res['DEF'] = {'n': int(len(y)), 'pos_med_q': int(np.median(q[y == 1])), 'neg_med_q': int(np.median(q[y == 0])),
                  'acc@q>=0': float(((q >= 0).astype(int) == y).mean()), 'auc': auc(pr, y)}
    xva = np.load(os.path.join(a.coco, 'val_x.npy')); yva = np.load(os.path.join(a.coco, 'val_y.npy'))
    sub = np.random.RandomState(0).choice(len(xva), min(3000, len(xva)), replace=False)
    qc, pc = infer(it, xva[sub])
    res['coco_val'] = {'n': int(len(sub)), 'acc@q>=0': float(((qc >= 0).astype(int) == yva[sub]).mean()),
                       'auc': auc(pc, yva[sub])}
    os.makedirs(os.path.dirname(a.out), exist_ok=True)
    json.dump(res, open(a.out, 'w'), indent=2, ensure_ascii=False)
    print(json.dumps(res, indent=2, ensure_ascii=False))


if __name__ == '__main__':
    main()
