# -*- coding: utf-8 -*-
"""v29 训练（板上口径）：int8 量化 + 固件 INPUT_SUB128=1 口径 + 暗光增强
- 输入：96x96 uint8（已按板上 crop1+1%/99% 拉伸预处理）
- 训练归一化：x/127.5 - 1（与固件 (int8)(u-128) 后 dequant=(q+1)/127.5 对齐）
- 增强：水平翻转、暗光(0.2~0.6)+高斯噪声+再拉伸、对比度、轻微平移
"""
import argparse, json, os
import numpy as np
import tensorflow as tf
from tensorflow import keras
from tensorflow.keras import layers
import sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from board_preprocess import stretch as stretch_np


def build_model():
    inp = keras.Input(shape=(96, 96, 1), name='input')
    x = inp
    for f, name in [(16, 'conv1'), (32, 'conv2'), (48, 'conv3'), (64, 'conv4'), (80, 'conv5')]:
        x = layers.Conv2D(f, 3, strides=2, padding='same', use_bias=False, name=name)(x)
        x = layers.BatchNormalization(name=name + '_bn')(x)
        x = layers.ReLU(name=name + '_relu')(x)
    x = layers.GlobalAveragePooling2D(name='gap')(x)
    x = layers.Dense(32, activation='relu', name='fc1')(x)
    out = layers.Dense(2, activation='softmax', name='fc2')(x)
    return keras.Model(inp, out, name='v29_person_96')


def aug_np(xb, yb):
    """numpy 批增强：xb uint8 (B,96,96,1) -> float32 (B,96,96,1) in [-1,1]"""
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
        if np.random.rand() < 0.7:                      # 暗光
            f = np.random.uniform(0.2, 0.6)
            im = im * f + np.random.normal(0.0, 3.0, im.shape)
            im = np.clip(im, 0, 255).astype(np.uint8)
            im = stretch_np(im)                          # 再经 STRETCH
        im = np.clip(im, 0, 255)
        if np.random.rand() < 0.5:                       # 对比度
            c = np.random.uniform(0.75, 1.25)
            m = im.mean()
            im = np.clip((im - m) * c + m, 0, 255)
        if np.random.rand() < 0.5:                       # 轻微平移 ±8%
            dx = int(np.random.randint(-7, 8)); dy = int(np.random.randint(-7, 8))
            im = np.roll(np.roll(im, dy, axis=0), dx, axis=1)
        out[i] = im
    xn = out / 127.5 - 1.0
    return xn[..., None].astype(np.float32), y


def make_ds(x, y, batch, training, seed=0):
    if training:
        ds = tf.data.Dataset.from_tensor_slices((x, y)).shuffle(min(len(x), 20000), seed=seed, reshuffle_each_iteration=True)
    else:
        ds = tf.data.Dataset.from_tensor_slices((x, y))
    ds = ds.batch(batch)
    if training:
        ds = ds.map(lambda xb, yb: tf.numpy_function(aug_np, [xb, yb], [tf.float32, tf.int64]),
                    num_parallel_calls=tf.data.AUTOTUNE)
        ds = ds.map(lambda xb, yb: (tf.reshape(xb, [-1, 96, 96, 1]), tf.reshape(yb, [-1])), num_parallel_calls=tf.data.AUTOTUNE)
    else:
        ds = ds.map(lambda xb, yb: (tf.cast(xb, tf.float32)[..., None] / 127.5 - 1.0, yb))
    return ds.prefetch(tf.data.AUTOTUNE)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--data', required=True)
    ap.add_argument('--out', required=True)
    ap.add_argument('--epochs', type=int, default=40)
    ap.add_argument('--batch', type=int, default=128)
    ap.add_argument('--lr', type=float, default=1e-3)
    ap.add_argument('--seed', type=int, default=0)
    a = ap.parse_args()
    os.makedirs(a.out, exist_ok=True)
    tf.random.set_seed(a.seed); np.random.seed(a.seed)

    xtr = np.load(os.path.join(a.data, 'train_x.npy')); ytr = np.load(os.path.join(a.data, 'train_y.npy'))
    xva = np.load(os.path.join(a.data, 'val_x.npy')); yva = np.load(os.path.join(a.data, 'val_y.npy'))
    print('train', xtr.shape, 'pos=%.3f' % ytr.mean(), 'val', xva.shape, 'pos=%.3f' % yva.mean())

    model = build_model()
    lines = []
    model.summary(print_fn=lambda s, **kw: lines.append(s))
    total = model.count_params()
    open(os.path.join(a.out, 'model_summary.txt'), 'w', encoding='utf-8').write('\n'.join(lines) + '\n\nTOTAL_PARAMS=%d\n' % total)
    print('TOTAL_PARAMS', total)
    assert total <= 100000

    ds_tr = make_ds(xtr, ytr, a.batch, True, a.seed)
    ds_va = make_ds(xva, yva, 256, False)
    steps = max(1, len(xtr) // a.batch)
    sched = keras.optimizers.schedules.CosineDecay(a.lr, decay_steps=steps * a.epochs, alpha=0.02)
    model.compile(optimizer=keras.optimizers.Adam(sched),
                  loss=keras.losses.SparseCategoricalCrossentropy(),
                  metrics=['accuracy'])
    ckpt = os.path.join(a.out, 'v29_best.keras')
    cbs = [keras.callbacks.ModelCheckpoint(ckpt, monitor='val_accuracy', save_best_only=True, verbose=1),
           keras.callbacks.CSVLogger(os.path.join(a.out, 'train_log.csv'))]
    model.fit(ds_tr, validation_data=ds_va, epochs=a.epochs, callbacks=cbs, verbose=2)
    best = keras.models.load_model(ckpt)
    va = best.evaluate(ds_va, verbose=0)
    print('BEST val_loss=%.4f val_acc=%.4f params=%d' % (va[0], va[1], total))
    json.dump({'params': int(total), 'val_loss': float(va[0]), 'val_acc': float(va[1]),
               'train_n': int(len(xtr)), 'val_n': int(len(xva))},
              open(os.path.join(a.out, 'train_result.json'), 'w'), indent=2)


if __name__ == '__main__':
    main()

