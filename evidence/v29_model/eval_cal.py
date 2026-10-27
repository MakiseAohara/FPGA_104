# -*- coding: utf-8 -*-
"""评估微调后 tflite 在 v29_scene D/E/F 与 COCO 验证上的表现（板上口径 u-128）"""
import argparse, csv, json, os
import numpy as np
from PIL import Image
import tensorflow as tf


def load(p):
    it = tf.lite.Interpreter(model_path=p); it.allocate_tensors(); return it


def infer(it, imgs):
    ind = it.get_input_details()[0]; outd = it.get_output_details()[0]
    osc, ozp = outd['quantization']
    qs, ps = [], []
    for im in imgs:
        q = np.clip(im.astype(np.int16) - 128, -128, 127).astype(np.int8)
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
    ap.add_argument('--frames', required=True)
    ap.add_argument('--labels', required=True)
    ap.add_argument('--coco', required=True)
    ap.add_argument('--out', required=True)
    a = ap.parse_args()
    it = load(a.tflite)
    rows = [r for r in csv.DictReader(open(a.labels, encoding='utf-8')) if r['label_intruder'] != '-1']
    res = {}
    allq, ally = [], []
    for seg in ('D', 'E', 'F'):
        imgs, ys = [], []
        for r in rows:
            if r['segment'] != seg:
                continue
            p = os.path.join(a.frames, r['file'])
            if not os.path.exists(p):
                continue
            im = np.asarray(Image.open(p).convert('L'), dtype=np.uint8)
            imgs.append(im); ys.append(int(r['label_intruder']))
        if not imgs:
            continue
        q, pr = infer(it, imgs)
        y = np.array(ys)
        rec = {'n': int(len(y)), 'pos_n': int((y == 1).sum()), 'neg_n': int((y == 0).sum()),
               'pos_med_q': int(np.median(q[y == 1])) if (y == 1).any() else None,
               'neg_med_q': int(np.median(q[y == 0])) if (y == 0).any() else None,
               'acc@q>=0': float(((q >= 0).astype(int) == y).mean()),
               'auc': auc(pr, y) if len(set(y)) > 1 else None}
        res[seg] = rec
        allq.append(q); ally.append(y)
    q = np.concatenate(allq); y = np.concatenate(ally)
    res['DEF'] = {'n': int(len(y)), 'pos_med_q': int(np.median(q[y == 1])),
                  'neg_med_q': int(np.median(q[y == 0])),
                  'acc@q>=0': float(((q >= 0).astype(int) == y).mean()), 'auc': auc(q.astype(float), y)}
    # COCO val
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
