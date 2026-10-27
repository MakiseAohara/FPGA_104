# -*- coding: utf-8 -*-
"""v29 场景校准微调：COCO 为主 + 场景为辅（20~30%/batch），强增强。
划分：v29_scene F 段整段验证；D、E 段 + 旧场景训练段做训练；COCO 验证同时监控。
"""
import argparse, csv, json, os, sys
import numpy as np
from PIL import Image
import tensorflow as tf
from tensorflow import keras
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from board_preprocess import stretch as stretch_np


def load_v29_scene(root, csv_path):
    rows = list(csv.DictReader(open(csv_path, encoding='utf-8')))
    seg = {}
    for r in rows:
        if r['label_intruder'] == '-1':
            continue
        p = os.path.join(root, r['file'])
        if not os.path.exists(p):
            continue
        img = np.asarray(Image.open(p).convert('L'), dtype=np.uint8)
        if img.shape != (96, 96):
            img = np.asarray(Image.fromarray(img).resize((96, 96), Image.BILINEAR), dtype=np.uint8)
        seg.setdefault(r['segment'], {'x': [], 'y': [], 'f': []})
        seg[r['segment']]['x'].append(img)
        seg[r['segment']]['y'].append(int(r['label_intruder']))
        seg[r['segment']]['f'].append(r['file'])
    return seg


def aug_batch(xb, yb):
    """强增强：亮度(0.5~1.3)、对比度、平移±10%、翻转、轻微缩放(0.9~1.1)"""
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
        # 缩放
        s = np.random.uniform(0.9, 1.1)
        if abs(s - 1.0) > 0.02:
            nh = max(8, int(H * s)); nw = max(8, int(W * s))
            pil = Image.fromarray(np.clip(im, 0, 255).astype(np.uint8)).resize((nw, nh), Image.BILINEAR)
            a = np.asarray(pil, dtype=np.float32)
            canvas = np.zeros((H, W), np.float32)
            y0 = max(0, (H - nh) // 2); x0 = max(0, (W - nw) // 2)
            canvas[y0:y0 + min(nh, H), x0:x0 + min(nw, W)] = a[:min(nh, H), :min(nw, W)]
            im = canvas
        # 亮度/对比度
        im = im * np.random.uniform(0.5, 1.3)
        m = im.mean()
        im = (im - m) * np.random.uniform(0.8, 1.2) + m
        im = np.clip(im, 0, 255)
        # 平移 ±10%
        dx = int(np.random.randint(-9, 10)); dy = int(np.random.randint(-9, 10))
        im = np.roll(np.roll(im, dy, axis=0), dx, axis=1)
        out[i] = im
    xn = out / 127.5 - 1.0
    return xn[..., None].astype(np.float32), y


def ds_make(x, y, batch, training, seed=0):
    ds = tf.data.Dataset.from_tensor_slices((x, y))
    if training:
        ds = ds.shuffle(min(len(x), 30000), seed=seed, reshuffle_each_iteration=True)
    ds = ds.batch(batch)
    if training:
        ds = ds.map(lambda a, b: tf.numpy_function(aug_batch, [a, b], [tf.float32, tf.int64]),
                    num_parallel_calls=tf.data.AUTOTUNE)
        ds = ds.map(lambda a, b: (tf.reshape(a, [-1, 96, 96, 1]), tf.reshape(b, [-1])))
    else:
        ds = ds.map(lambda a, b: (tf.cast(a, tf.float32)[..., None] / 127.5 - 1.0, b))
    return ds.prefetch(tf.data.AUTOTUNE)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--model', required=True)
    ap.add_argument('--coco', required=True)
    ap.add_argument('--scene-v29', required=True, help='v29_scene 帧目录')
    ap.add_argument('--labels-v29', required=True)
    ap.add_argument('--scene-old', required=True, help='旧场景 npy 目录（scene_train_x/y.npy）')
    ap.add_argument('--out', required=True)
    ap.add_argument('--epochs', type=int, default=8)
    ap.add_argument('--lr', type=float, default=2e-4)
    ap.add_argument('--batch', type=int, default=128)
    ap.add_argument('--coco-n', type=int, default=12000)
    ap.add_argument('--scene-frac', type=float, default=0.25)
    a = ap.parse_args()
    os.makedirs(a.out, exist_ok=True)

    seg = load_v29_scene(a.scene_v29, a.labels_v29)
    tr = {'x': [], 'y': []}
    for k in ('D', 'E'):
        if k in seg:
            tr['x'] += seg[k]['x']; tr['y'] += seg[k]['y']
    va = seg['F']
    print('v29_scene train D+E:', len(tr['y']), 'pos=%.3f' % np.mean(tr['y']))
    print('v29_scene val F   :', len(va['y']), 'pos=%.3f' % np.mean(va['y']))

    xo = np.load(os.path.join(a.scene_old, 'scene_train_x.npy')); yo = np.load(os.path.join(a.scene_old, 'scene_train_y.npy'))
    sx = np.concatenate([np.stack(tr['x']), xo], 0); sy = np.concatenate([np.asarray(tr['y'], np.uint8), yo], 0)
    print('scene train total:', len(sy), 'pos=%.3f' % sy.mean())

    xc = np.load(os.path.join(a.coco, 'train_x.npy')); yc = np.load(os.path.join(a.coco, 'train_y.npy'))
    xcv = np.load(os.path.join(a.coco, 'val_x.npy')); ycv = np.load(os.path.join(a.coco, 'val_y.npy'))
    rng = np.random.RandomState(0)
    ci = rng.choice(len(xc), min(a.coco_n, len(xc)), replace=False)
    xc, yc = xc[ci], yc[ci]
    # 场景样本重复，使其占 batch 的 scene_frac
    rep = max(1, int(round(len(xc) * a.scene_frac / max(1, len(sy)) / (1 - a.scene_frac))))
    sx2 = np.tile(sx, (rep, 1, 1)); sy2 = np.tile(sy, rep)
    x_tr = np.concatenate([xc, sx2], 0); y_tr = np.concatenate([yc, sy2], 0)
    print('mix train:', x_tr.shape, 'scene rep=%d' % rep, 'scene frac=%.2f' % (len(sy2) / len(y_tr)))

    xf = np.stack(va['x']); yf = np.asarray(va['y'], np.uint8)
    model = keras.models.load_model(a.model)
    ds_tr = ds_make(x_tr, y_tr, a.batch, True, 31)
    ds_f = ds_make(xf, yf, 64, False)
    ds_cv = ds_make(xcv, ycv, 256, False)

    model.compile(optimizer=keras.optimizers.Adam(a.lr),
                  loss=keras.losses.SparseCategoricalCrossentropy(), metrics=['accuracy'])
    best = {'score': -1}
    hist = []
    for ep in range(a.epochs):
        model.fit(ds_tr, epochs=1, verbose=2)
        pf = model.predict(ds_f, verbose=0)[:, 1]
        pc = model.predict(ds_cv, verbose=0)[:, 1]
        coco_acc = float(((pc >= 0.5).astype(int) == ycv).mean())
        pos_med = float(np.median(pf[yf == 1])); neg_med = float(np.median(pf[yf == 0]))
        order = np.argsort(-pf); ys = yf[order]
        tpr = np.cumsum(ys) / max(ys.sum(), 1); fpr = np.cumsum(1 - ys) / max((1 - ys).sum(), 1)
        auc = float(np.trapz(tpr, fpr))
        acc0 = float(((pf >= 0.5).astype(int) == yf).mean())
        rec = {'epoch': ep, 'F_pos_med': pos_med, 'F_neg_med': neg_med, 'F_auc': auc,
               'F_acc@0.5': acc0, 'coco_acc': coco_acc}
        hist.append(rec); print('EPOCH', rec)
        score = auc + (pos_med - neg_med)
        if score > best['score']:
            best = {'score': score, **rec}
            model.save(os.path.join(a.out, 'v29_scene_best.keras'))
    json.dump({'history': hist, 'best': best, 'scene_train_n': int(len(sy2)), 'coco_n': int(len(xc))},
              open(os.path.join(a.out, 'scene_mix_result.json'), 'w'), indent=2, ensure_ascii=False)
    print('BEST', best)


if __name__ == '__main__':
    main()

