# -*- coding: utf-8 -*-
"""v29 人检模型训练（96x96x1，5 Conv + GAP + 2 Dense，<=100K 参数）

用法：
  python train_v29.py --data D:\FPGA\mmt\work_v29\data\vww96 --out D:\FPGA\mmt\work_v29\out
按任务书要求：Adam、batch 128、~30 epoch、亮度/对比度/水平翻转/轻微平移增强。
"""
import argparse, json, os, csv
import numpy as np
import tensorflow as tf
from tensorflow import keras
from tensorflow.keras import layers

def build_model():
    inp = keras.Input(shape=(96, 96, 1), name='input')
    x = inp
    for f, name in [(16, 'conv1'), (32, 'conv2'), (48, 'conv3'), (64, 'conv4'), (80, 'conv5')]:
        x = layers.Conv2D(f, 3, strides=2, padding='same', use_bias=False, name=name)(x)
        x = layers.BatchNormalization(name=name + '_bn')(x)
        x = layers.ReLU(name=name + '_relu')(x)
    x = layers.GlobalAveragePooling2D(name='gap')(x)
    x = layers.Dense(32, activation='relu', name='fc1')(x)
    # 输出与板上现有模型一致：2 类 softmax（person=class 1），量化后 int8 scale=1/256 zp=-128
    out = layers.Dense(2, activation='softmax', name='fc2')(x)
    return keras.Model(inp, out, name='v29_person_96')

def make_ds(x, y, batch, training, seed=0, norm='pm1'):
    ds = tf.data.Dataset.from_tensor_slices((x, y))
    if training:
        ds = ds.shuffle(min(len(x), 20000), seed=seed, reshuffle_each_iteration=True)
    ds = ds.batch(batch)
    def prep(xb, yb):
        xb = tf.cast(xb, tf.float32)
        xb = xb / 127.5 - 1.0 if norm == 'pm1' else xb / 255.0
        xb = tf.expand_dims(xb, -1)
        if training:
            # 水平翻转
            xb = tf.cond(tf.random.uniform([]) < 0.5, lambda: tf.image.flip_left_right(xb), lambda: xb)
            # 亮度 / 对比度
            xb = tf.image.random_brightness(xb, 0.3)
            xb = tf.image.random_contrast(xb, 0.7, 1.3)
            # 轻微平移（最大 8%）
            xb = tf.image.resize_with_crop_or_pad(xb, 108, 108)
            xb = tf.image.random_crop(xb, [tf.shape(xb)[0], 96, 96, 1])
            xb = tf.clip_by_value(xb, -1.0, 1.0) if norm == 'pm1' else tf.clip_by_value(xb, 0.0, 1.0)
        return xb, yb
    return ds.map(prep, num_parallel_calls=tf.data.AUTOTUNE).prefetch(tf.data.AUTOTUNE)

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--data', required=True)
    ap.add_argument('--out', required=True)
    ap.add_argument('--epochs', type=int, default=30)
    ap.add_argument('--batch', type=int, default=128)
    ap.add_argument('--lr', type=float, default=1e-3)
    ap.add_argument('--seed', type=int, default=0)
    ap.add_argument('--norm', default='pm1', choices=['pm1','0to1'])
    args = ap.parse_args()
    os.makedirs(args.out, exist_ok=True)
    tf.random.set_seed(args.seed); np.random.seed(args.seed)

    xtr = np.load(os.path.join(args.data, 'train_x.npy'))
    ytr = np.load(os.path.join(args.data, 'train_y.npy'))
    xva = np.load(os.path.join(args.data, 'val_x.npy'))
    yva = np.load(os.path.join(args.data, 'val_y.npy'))
    print('train', xtr.shape, 'pos=%.3f' % ytr.mean(), 'val', xva.shape, 'pos=%.3f' % yva.mean())

    model = build_model()
    lines = []
    model.summary(print_fn=lambda s, **kw: lines.append(s))
    total = model.count_params()
    print('\n'.join(lines))
    with open(os.path.join(args.out, 'model_summary.txt'), 'w', encoding='utf-8') as f:
        f.write('\n'.join(lines) + '\n\nTOTAL_PARAMS=%d\n' % total)
    print('TOTAL_PARAMS =', total)
    assert total <= 100000, '参数量超过 100K'

    ds_tr = make_ds(xtr, ytr, args.batch, True, args.seed, args.norm)
    ds_va = make_ds(xva, yva, 256, False, 0, args.norm)
    steps = len(xtr) // args.batch
    sched = keras.optimizers.schedules.CosineDecay(args.lr, decay_steps=steps * args.epochs, alpha=0.05)
    model.compile(optimizer=keras.optimizers.Adam(sched),
                  loss=keras.losses.SparseCategoricalCrossentropy(from_logits=False),
                  metrics=['accuracy'])
    ckpt = os.path.join(args.out, 'v29_best.keras')
    cbs = [
        keras.callbacks.ModelCheckpoint(ckpt, monitor='val_accuracy', save_best_only=True, verbose=1),
        keras.callbacks.CSVLogger(os.path.join(args.out, 'train_log.csv')),
    ]
    hist = model.fit(ds_tr, validation_data=ds_va, epochs=args.epochs, callbacks=cbs, verbose=2)
    model.save(os.path.join(args.out, 'v29_final.keras'))
    best = keras.models.load_model(ckpt)
    va = best.evaluate(ds_va, verbose=0)
    print('BEST val_loss=%f val_acc=%f params=%d' % (va[0], va[1], total))
    json.dump({'params': int(total), 'val_loss': float(va[0]), 'val_acc': float(va[1]),
               'train_n': int(len(xtr)), 'val_n': int(len(xva))},
              open(os.path.join(args.out, 'train_result.json'), 'w'), indent=2)

if __name__ == '__main__':
    main()



