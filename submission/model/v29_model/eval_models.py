# -*- coding: utf-8 -*-
"""新旧 TFLite 模型对比：
  A) val 集准确率（正常归一化 x/127.5-1 后量化）
  B) 板上固件的真实输入口径（uint8 位重解释成 int8：u<128 -> u, u>=128 -> u-256）
  C) v27 板上 96x96 帧（按 manual_events_raw.csv 时间线标注）上的 person 分数
"""
import argparse, csv, glob, json, os
import numpy as np
from PIL import Image

def load_tflite(path):
    import tensorflow as tf
    it = tf.lite.Interpreter(model_path=path)
    it.allocate_tensors()
    return it

def infer(it, imgs_u8, mode):
    ind = it.get_input_details()[0]; outd = it.get_output_details()[0]
    scale, zp = ind['quantization']
    oscale, ozp = outd['quantization']
    scores = []
    for img in imgs_u8:
        x = img.astype(np.float32)
        if mode == 'normal':
            xn = x / 127.5 - 1.0
            q = np.round(xn / scale) + zp
            q = np.clip(q, -128, 127).astype(np.int8)
        else:  # board: (int8_t)u 位重解释
            q = x.astype(np.int8)
        it.set_tensor(ind['index'], q[None, :, :, None])
        it.invoke()
        o = it.get_tensor(outd['index'])[0]
        # person = class 1
        p = (float(o[1]) - ozp) * oscale
        scores.append(p)
    return np.array(scores)

def v27_labels(frames_csv, events_csv):
    ev = []
    with open(events_csv, newline='', encoding='utf-8') as f:
        for r in csv.DictReader(f):
            if r['device_ms_latest']:
                ev.append((r['event'], int(r['device_ms_latest'])))
    ev.sort(key=lambda t: t[1])
    person = None
    out = {}
    with open(frames_csv, newline='', encoding='utf-8') as f:
        for r in csv.DictReader(f):
            ms = int(r['device_ms'])
            # 找到该时刻前最近的事件
            state = 0
            for name, t in ev:
                if t <= ms:
                    if name in ('ENTER', 'CHAIR_START', 'HEAD_DOWN_START', 'SIDE_START'):
                        state = 1
                    elif name in ('LEAVE', 'CHAIR_END', 'HEAD_DOWN_END', 'SIDE_END'):
                        state = 0
            out[r['file']] = {'ms': ms, 'label': state, 'old_p': int(r['p']) if r.get('p') else None}
    return out

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--data', required=True)
    ap.add_argument('--old', required=True)
    ap.add_argument('--new', required=True)
    ap.add_argument('--frames', required=True, help='evidence/v27_gate 目录')
    ap.add_argument('--out', required=True)
    args = ap.parse_args()
    os.makedirs(args.out, exist_ok=True)

    xva = np.load(os.path.join(args.data, 'val_x.npy'))
    yva = np.load(os.path.join(args.data, 'val_y.npy'))
    sub = np.random.RandomState(0).choice(len(xva), size=min(3000, len(xva)), replace=False)
    xv, yv = xva[sub], yva[sub]

    models = {'old_mobilenet': args.old, 'new_v29': args.new}
    report = {}
    for name, path in models.items():
        it = load_tflite(path)
        for mode in ('normal', 'board'):
            s = infer(it, xv, mode)
            pred = (s >= 0.5).astype(int)
            acc = float((pred == yv).mean())
            # AUC
            order = np.argsort(-s)
            ysort = yv[order]
            tp = np.cumsum(ysort); fp = np.cumsum(1 - ysort)
            tpr = tp / max(ysort.sum(), 1); fpr = fp / max((1 - ysort).sum(), 1)
            auc = float(np.trapz(tpr, fpr))
            report['%s_%s' % (name, mode)] = {'val_acc@0.5': acc, 'auc': auc,
                                             'score_pos_mean': float(s[yv == 1].mean()) if (yv == 1).any() else None,
                                             'score_neg_mean': float(s[yv == 0].mean()) if (yv == 0).any() else None}
        # v27 帧
        lab = v27_labels(os.path.join(args.frames, 'frames.csv'), os.path.join(args.frames, 'manual_events_raw.csv'))
        imgs, ys, names = [], [], []
        for rel, meta in sorted(lab.items()):
            p = os.path.join(args.frames, rel)
            if not os.path.exists(p):
                continue
            imgs.append(np.asarray(Image.open(p).convert('L'), dtype=np.uint8))
            ys.append(meta['label']); names.append(os.path.basename(rel))
        for mode in ('normal', 'board'):
            s = infer(it, imgs, mode)
            report['%s_v27_%s' % (name, mode)] = {
                'frames': names, 'labels': ys, 'scores': [float(v) for v in s],
                'argmax_person': [int(v >= 0.5) for v in s],
                'mean_pos': float(np.mean([v for v, y in zip(s, ys) if y == 1])) if any(ys) else None,
                'mean_neg': float(np.mean([v for v, y in zip(s, ys) if y == 0])) if any(y == 0 for y in ys) else None,
            }
    json.dump(report, open(os.path.join(args.out, 'compare.json'), 'w'), indent=2, ensure_ascii=False)
    # 可读表
    lines = ['| 模型/口径 | val acc@0.5 | AUC | val 正均值 | val 负均值 | v27 正均值 | v27 负均值 |',
             '|---|---|---|---|---|---|---|']
    for k, v in report.items():
        if 'val_acc@0.5' in v:
            lines.append('| %s | %.4f | %.4f | %.3f | %.3f | - | - |' % (
                k, v['val_acc@0.5'], v['auc'],
                v['score_pos_mean'] if v['score_pos_mean'] is not None else float('nan'),
                v['score_neg_mean'] if v['score_neg_mean'] is not None else float('nan')))
        else:
            lines.append('| %s | - | - | - | - | %.3f | %.3f |' % (
                k, v['mean_pos'] if v['mean_pos'] is not None else float('nan'),
                v['mean_neg'] if v['mean_neg'] is not None else float('nan')))
    txt = '\n'.join(lines)
    open(os.path.join(args.out, 'compare.md'), 'w', encoding='utf-8').write(txt + '\n')
    print(txt)

if __name__ == '__main__':
    main()

