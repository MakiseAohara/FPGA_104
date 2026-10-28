# -*- coding: utf-8 -*-
"""第二轮场景微调（白天数据）
数据：
  - COCO（vww96_board，板上口径已预处理）
  - v29_scene：log 解码，D/E 训练，F 整段验证
  - 白天：comms/scene_labels_v29_day（PNG = 像素 u），训练 wall<15:13:00，验证 wall>=15:13:00
  - 旧场景：data/scene（scene_train_x/y.npy）
输入一律 (u-128)/127.5（板上 INPUT_SUB128=1）。
选优：v29_scene F 段 + 白天验证段的 int8 中位数分离 + AUC，同时监控 COCO。
"""
import argparse, csv, json, os, re, sys
import numpy as np
from PIL import Image
import tensorflow as tf
from tensorflow import keras
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from decode_scene_log import parse_log


def load_day(labels_csv):
    base = os.path.dirname(labels_csv)
    tr_x, tr_y, va_x, va_y = [], [], [], []
    for r in csv.DictReader(open(labels_csv, encoding='utf-8')):
        if r['label_intruder'] not in ('0', '1'):
            continue
        p = os.path.join(base, r['file'])
        if not os.path.exists(p):
            p = r['file']
        u = np.asarray(Image.open(p).convert('L'), dtype=np.uint8)
        y = int(r['label_intruder'])
        if r['wall'] >= '2026-10-28T15:13:00':
            va_x.append(u); va_y.append(y)
        else:
            tr_x.append(u); tr_y.append(y)
    return (np.stack(tr_x), np.asarray(tr_y, np.uint8),
            np.stack(va_x), np.asarray(va_y, np.uint8))


def load_log_scene(log, labels):
    frames = parse_log(log)
    by_key = {(f['stage'], f['t']): f for f in frames}
    seg = {}
    for r in csv.DictReader(open(labels, encoding='utf-8')):
        if r['label_intruder'] == '-1':
            continue
        m = re.match(r'([A-F])_t(\d+)_p(-?\d+)\.png', r['file'])
        if not m:
            continue
        f = by_key.get((m.group(1), int(m.group(2))))
        if f is None:
            continue
        seg.setdefault(f['stage'], {'x': [], 'y': []})
        seg[f['stage']]['x'].append(f['pixels'])
        seg[f['stage']]['y'].append(int(r['label_intruder']))
    return seg


def aug_batch(xb, yb):
    arr = np.asarray(xb)
    if arr.ndim == 4:
        arr = arr[..., 0]
    x = arr.astype(np.float32)
    y = np.asarray(yb).astype(np.int64)
    B, H, W = x.shape
    out = np.empty_like(x)
    for i in range(B):
        im = x[i].copy()
        if np.random.rand() < 0.5:
            im = im[:, ::-1].copy()
        s = np.random.uniform(0.85, 1.15)
        if abs(s - 1.0) > 0.02:
            nh = max(8, int(H * s)); nw = max(8, int(W * s))
            pil = Image.fromarray(np.clip(im, 0, 255).astype(np.uint8)).resize((nw, nh), Image.BILINEAR)
            a = np.asarray(pil, dtype=np.float32)
            canvas = np.zeros((H, W), np.float32)
            y0 = max(0, (H - nh) // 2); x0 = max(0, (W - nw) // 2)
            canvas[y0:y0 + min(nh, H), x0:x0 + min(nw, W)] = a[:min(nh, H), :min(nw, W)]
            im = canvas
        im = im * np.random.uniform(0.55, 1.35)
        m = im.mean()
        im = (im - m) * np.random.uniform(0.75, 1.25) + m
        im = np.clip(im, 0, 255)
        dx = int(np.random.randint(-9, 10)); dy = int(np.random.randint(-9, 10))
        im = np.roll(np.roll(im, dy, axis=0), dx, axis=1)
        out[i] = im
    xn = (out - 128.0) / 127.5
    return xn[..., None].astype(np.float32), y


def ds_make(x, y, batch, training, seed=0):
    ds = tf.data.Dataset.from_tensor_slices((x, y))
    if training:
        ds = ds.shuffle(min(len(x), 40000), seed=seed, reshuffle_each_iteration=True)
    ds = ds.batch(batch)
    if training:
        ds = ds.map(lambda a, b: tf.numpy_function(aug_batch, [a, b], [tf.float32, tf.int64]),
                    num_parallel_calls=tf.data.AUTOTUNE)
        ds = ds.map(lambda a, b: (tf.reshape(a, [-1, 96, 96, 1]), tf.reshape(b, [-1])))
    else:
        ds = ds.map(lambda a, b: (tf.cast(a, tf.float32)[..., None] / 127.5 - 1.0, b))
    return ds.prefetch(tf.data.AUTOTUNE)


def med_metrics(model, x, y):
    p = model.predict(ds_make(x, y, 128, False), verbose=0)[:, 1]
    q = np.round(p / (1.0 / 256.0)) - 128
    pos = q[y == 1]; neg = q[y == 0]
    order = np.argsort(-p); ys = y[order]
    tpr = np.cumsum(ys) / max(ys.sum(), 1); fpr = np.cumsum(1 - ys) / max((1 - ys).sum(), 1)
    return {'pos_med_q': int(np.median(pos)) if len(pos) else None,
            'neg_med_q': int(np.median(neg)) if len(neg) else None,
            'acc@q0': float(((q >= 0).astype(int) == y).mean()),
            'auc': float(np.trapz(tpr, fpr)) if len(set(y)) > 1 else None}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--model', required=True)
    ap.add_argument('--coco', required=True)
    ap.add_argument('--log', required=True)
    ap.add_argument('--labels', required=True)
    ap.add_argument('--day-labels', required=True)
    ap.add_argument('--scene-old', required=True)
    ap.add_argument('--out', required=True)
    ap.add_argument('--epochs', type=int, default=12)
    ap.add_argument('--lr', type=float, default=1.5e-4)
    ap.add_argument('--batch', type=int, default=128)
    ap.add_argument('--coco-n', type=int, default=14000)
    ap.add_argument('--scene-frac', type=float, default=0.32)
    a = ap.parse_args()
    os.makedirs(a.out, exist_ok=True)

    seg = load_log_scene(a.log, a.labels)
    trx = seg['D']['x'] + seg['E']['x']
    trY = seg['D']['y'] + seg['E']['y']
    fx = np.stack(seg['F']['x']); fy = np.asarray(seg['F']['y'], np.uint8)
    day_tr_x, day_tr_y, day_va_x, day_va_y = load_day(a.day_labels)
    print('v29_scene D+E:', len(trY), 'F:', len(fy))
    print('day train:', len(day_tr_y), 'val:', len(day_va_y))

    xo = np.load(os.path.join(a.scene_old, 'scene_train_x.npy'))
    yo = np.load(os.path.join(a.scene_old, 'scene_train_y.npy'))
    sx = np.concatenate([np.stack(trx), day_tr_x, xo], 0)
    sy = np.concatenate([np.asarray(trY, np.uint8), day_tr_y, yo], 0)
    print('scene train total:', len(sy), 'pos=%.3f' % sy.mean())

    xc = np.load(os.path.join(a.coco, 'train_x.npy')); yc = np.load(os.path.join(a.coco, 'train_y.npy'))
    xcv = np.load(os.path.join(a.coco, 'val_x.npy')); ycv = np.load(os.path.join(a.coco, 'val_y.npy'))
    rng = np.random.RandomState(0)
    ci = rng.choice(len(xc), min(a.coco_n, len(xc)), replace=False)
    xc, yc = xc[ci], yc[ci]
    rep = max(1, int(round(len(xc) * a.scene_frac / max(1, len(sy)) / (1 - a.scene_frac))))
    sx2 = np.tile(sx, (rep, 1, 1)); sy2 = np.tile(sy, rep)
    x_tr = np.concatenate([xc, sx2], 0); y_tr = np.concatenate([yc, sy2], 0)
    print('mix train:', x_tr.shape, 'scene rep=%d' % rep, 'scene frac=%.2f' % (len(sy2) / len(y_tr)))

    # COCO 验证子集（每 epoch 同 3000 张）
    cvi = np.random.RandomState(1).choice(len(xcv), min(3000, len(xcv)), replace=False)
    xcv_s, ycv_s = xcv[cvi], ycv[cvi]
    ds_cv = ds_make(xcv_s, ycv_s, 256, False)

    model = keras.models.load_model(a.model)
    ds_tr = ds_make(x_tr, y_tr, a.batch, True, 41)
    best = {'score': -1}; hist = []
    for ep in range(a.epochs):
        model.fit(ds_tr, epochs=1, verbose=2)
        mF = med_metrics(model, fx, fy)
        mD = med_metrics(model, day_va_x, day_va_y)
        pc = model.predict(ds_cv, verbose=0)[:, 1]
        coco_acc = float(((pc >= 0.5).astype(int) == ycv_s).mean())
        rec = {'epoch': ep, 'F': mF, 'day': mD, 'coco_acc': coco_acc}
        # 目标：两验证集 pos>+30 / neg<-30，COCO 不降
        margin = (mF['pos_med_q'] - mF['neg_med_q']) + (mD['pos_med_q'] - mD['neg_med_q'])
        score = margin + 200 * ((mF['auc'] or 0) + (mD['auc'] or 0)) + 100 * coco_acc
        rec['score'] = score
        hist.append(rec)
        print('EPOCH', json.dumps(rec, ensure_ascii=False))
        if score > best['score']:
            best = dict(rec); best['score'] = score
            model.save(os.path.join(a.out, 'v29_day_best.keras'))
    json.dump({'history': hist, 'best': best,
               'scene_train_n': int(len(sy2)), 'coco_n': int(len(xc)),
               'day_train_n': int(len(day_tr_y)), 'day_val_n': int(len(day_va_y))},
              open(os.path.join(a.out, 'mix_result.json'), 'w'), indent=2, ensure_ascii=False)
    print('BEST', json.dumps(best, ensure_ascii=False))


if __name__ == '__main__':
    main()
