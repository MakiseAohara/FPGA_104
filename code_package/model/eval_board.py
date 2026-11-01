# -*- coding: utf-8 -*-
"""板上口径评估：像素 u -> (int8)(u-128)（固件 INPUT_SUB128=1）
- COCO val（96x96，已按板预处理）
- 场景留出集（v25/v27/v28 段）
- v27 帧新旧分数对比（旧 = frames.csv 记录的 p）
"""
import argparse, csv, json, os
import numpy as np
from PIL import Image
import tensorflow as tf


def load(path):
    it = tf.lite.Interpreter(model_path=path)
    it.allocate_tensors()
    return it


def infer_board(it, imgs):
    ind = it.get_input_details()[0]; outd = it.get_output_details()[0]
    osc, ozp = outd['quantization']
    probs, qs = [], []
    for img in imgs:
        q = np.clip(img.astype(np.int16) - 128, -128, 127).astype(np.int8)
        it.set_tensor(ind['index'], q[None, :, :, None]); it.invoke()
        o = it.get_tensor(outd['index'])[0]
        qs.append(int(o[1])); probs.append((float(o[1]) - ozp) * osc)
    return np.array(probs), np.array(qs)


def auc_score(s, y):
    order = np.argsort(-s); ys = y[order]
    tpr = np.cumsum(ys) / max(ys.sum(), 1); fpr = np.cumsum(1 - ys) / max((1 - ys).sum(), 1)
    return float(np.trapz(tpr, fpr))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--new', required=True)
    ap.add_argument('--coco-data', required=True)
    ap.add_argument('--scene-data', required=True)
    ap.add_argument('--frames', required=True)
    ap.add_argument('--out', required=True)
    ap.add_argument('--tag', default='v29')
    a = ap.parse_args()
    os.makedirs(a.out, exist_ok=True)
    it = load(a.new)
    report = {}

    # COCO val
    xva = np.load(os.path.join(a.coco_data, 'val_x.npy')); yva = np.load(os.path.join(a.coco_data, 'val_y.npy'))
    sub = np.random.RandomState(0).choice(len(xva), min(3000, len(xva)), replace=False)
    p, q = infer_board(it, xva[sub])
    pred = (q >= 0).astype(int)  # 阈值：person 概率 >= 0.5 对应 q >= 0
    report['coco_val'] = {'n': int(len(sub)), 'acc@q>=0': float((pred == yva[sub]).mean()),
                          'auc': auc_score(p, yva[sub]),
                          'pos_mean': float(p[yva[sub] == 1].mean()), 'neg_mean': float(p[yva[sub] == 0].mean())}

    # 场景留出集
    xva2 = np.load(os.path.join(a.scene_data, 'scene_val_x.npy')); yva2 = np.load(os.path.join(a.scene_data, 'scene_val_y.npy'))
    p2, q2 = infer_board(it, xva2)
    pred2 = (q2 >= 0).astype(int)
    report['scene_val'] = {'n': int(len(yva2)), 'acc@q>=0': float((pred2 == yva2).mean()),
                           'auc': auc_score(p2, yva2),
                           'pos_mean': float(p2[yva2 == 1].mean()) if (yva2 == 1).any() else None,
                           'neg_mean': float(p2[yva2 == 0].mean()) if (yva2 == 0).any() else None,
                           'tp': int(((pred2 == 1) & (yva2 == 1)).sum()), 'fp': int(((pred2 == 1) & (yva2 == 0)).sum()),
                           'tn': int(((pred2 == 0) & (yva2 == 0)).sum()), 'fn': int(((pred2 == 0) & (yva2 == 1)).sum())}

    # v27 帧新旧对比
    rows = list(csv.DictReader(open(os.path.join(a.frames, 'frames.csv'), encoding='utf-8')))
    imgs = [np.asarray(Image.open(os.path.join(a.frames, r['file'])).convert('L'), dtype=np.uint8) for r in rows]
    p3, q3 = infer_board(it, imgs)
    cmp_rows = []
    for i, r in enumerate(rows):
        cmp_rows.append({'file': os.path.basename(r['file']), 'old_p_int8': int(r['p']),
                         'old_p': (int(r['p']) + 128) / 256.0,
                         'new_p': float(p3[i]), 'new_q': int(q3[i])})
    report['v27'] = cmp_rows
    json.dump(report, open(os.path.join(a.out, f'eval_{a.tag}.json'), 'w'), indent=2, ensure_ascii=False)

    print('COCO val:', report['coco_val'])
    print('scene  val:', report['scene_val'])
    print('| frame | old p | new p | new q |')
    print('|---|---|---|---|')
    for r in cmp_rows:
        print('| %s | %.3f | %.3f | %d |' % (r['file'], r['old_p'], r['new_p'], r['new_q']))


if __name__ == '__main__':
    main()
