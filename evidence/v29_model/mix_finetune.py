# -*- coding: utf-8 -*-
"""混合微调：COCO（板上口径）+ 场景训练段（正样本过采样），保持通用性同时适配板上场景。
验证：场景留出段（v25/v27/v28）+ COCO val 子集。
"""
import argparse, json, os, sys
import numpy as np
import tensorflow as tf
from tensorflow import keras
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from train_board import aug_np


def aug_batch(xb, yb):
    return tf.numpy_function(aug_np, [xb, yb], [tf.float32, tf.int64])


def ds_from(x, y, batch, training, seed=0):
    ds = tf.data.Dataset.from_tensor_slices((x, y))
    if training:
        ds = ds.shuffle(min(len(x), 20000), seed=seed, reshuffle_each_iteration=True)
    ds = ds.batch(batch)
    if training:
        ds = ds.map(aug_batch, num_parallel_calls=tf.data.AUTOTUNE)
        ds = ds.map(lambda a, b: (tf.reshape(a, [-1, 96, 96, 1]), tf.reshape(b, [-1])))
    else:
        ds = ds.map(lambda a, b: (tf.cast(a, tf.float32)[..., None] / 127.5 - 1.0, b))
    return ds.prefetch(tf.data.AUTOTUNE)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--model', required=True)
    ap.add_argument('--coco', required=True)
    ap.add_argument('--scene', required=True)
    ap.add_argument('--out', required=True)
    ap.add_argument('--epochs', type=int, default=8)
    ap.add_argument('--lr', type=float, default=2e-4)
    ap.add_argument('--batch', type=int, default=128)
    ap.add_argument('--coco-subset', type=int, default=8000)
    ap.add_argument('--pos-oversample', type=int, default=3)
    a = ap.parse_args()
    os.makedirs(a.out, exist_ok=True)

    xc = np.load(os.path.join(a.coco, 'train_x.npy')); yc = np.load(os.path.join(a.coco, 'train_y.npy'))
    xs = np.load(os.path.join(a.scene, 'scene_train_x.npy')); ys = np.load(os.path.join(a.scene, 'scene_train_y.npy'))
    xcv = np.load(os.path.join(a.coco, 'val_x.npy')); ycv = np.load(os.path.join(a.coco, 'val_y.npy'))
    xsv = np.load(os.path.join(a.scene, 'scene_val_x.npy')); ysv = np.load(os.path.join(a.scene, 'scene_val_y.npy'))

    rng = np.random.RandomState(0)
    ci = rng.choice(len(xc), min(a.coco_subset, len(xc)), replace=False)
    xc, yc = xc[ci], yc[ci]
    # 场景正样本过采样
    pos = np.where(ys == 1)[0]; neg = np.where(ys == 0)[0]
    idx = np.concatenate([np.repeat(pos, a.pos_oversample), neg])
    xs, ys = xs[idx], ys[idx]
    x_tr = np.concatenate([xc, xs], 0); y_tr = np.concatenate([yc, ys], 0)
    print('mix train', x_tr.shape, 'pos=%.3f' % y_tr.mean(), 'scene val', xsv.shape, 'pos=%.3f' % ysv.mean())

    model = keras.models.load_model(a.model)
    ds_tr = ds_from(x_tr, y_tr, a.batch, True, 11)
    ds_sv = ds_from(xsv, ysv, 64, False)
    ds_cv = ds_from(xcv, ycv, 256, False)
    model.compile(optimizer=keras.optimizers.Adam(a.lr),
                  loss=keras.losses.SparseCategoricalCrossentropy(), metrics=['accuracy'])
    ck = os.path.join(a.out, 'v29_mix_best.keras')
    cbs = [keras.callbacks.ModelCheckpoint(ck, monitor='val_accuracy', save_best_only=True, verbose=1),
           keras.callbacks.CSVLogger(os.path.join(a.out, 'mix_log.csv'))]
    model.fit(ds_tr, validation_data=ds_sv, epochs=a.epochs, callbacks=cbs, verbose=2)
    best = keras.models.load_model(ck)
    sv = best.evaluate(ds_sv, verbose=0); cv = best.evaluate(ds_cv, verbose=0)
    print('MIX scene_val_acc=%.4f coco_val_acc=%.4f' % (sv[1], cv[1]))
    json.dump({'scene_val_acc': float(sv[1]), 'coco_val_acc': float(cv[1]),
               'mix_train_n': int(len(y_tr)), 'scene_train_n': int(len(xs))},
              open(os.path.join(a.out, 'mix_result.json'), 'w'), indent=2)


if __name__ == '__main__':
    main()
