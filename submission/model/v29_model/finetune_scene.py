# -*- coding: utf-8 -*-
"""在场景数据（板上口径）上微调 COCO 预训练模型。
- 训练：scene_train（339 张），验证：scene_val（148 张，v25/v27/v28 段留出）
- 低学习率 + 增强（翻转/暗光/平移），早停防止过拟合
"""
import argparse, json, os, sys
import numpy as np
import tensorflow as tf
from tensorflow import keras
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from train_board import aug_np, make_ds


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--model', required=True)
    ap.add_argument('--data', required=True)
    ap.add_argument('--out', required=True)
    ap.add_argument('--epochs', type=int, default=12)
    ap.add_argument('--lr', type=float, default=1e-4)
    ap.add_argument('--batch', type=int, default=32)
    a = ap.parse_args()
    os.makedirs(a.out, exist_ok=True)
    model = keras.models.load_model(a.model)
    xtr = np.load(os.path.join(a.data, 'scene_train_x.npy')); ytr = np.load(os.path.join(a.data, 'scene_train_y.npy'))
    xva = np.load(os.path.join(a.data, 'scene_val_x.npy')); yva = np.load(os.path.join(a.data, 'scene_val_y.npy'))
    print('scene train', xtr.shape, 'pos=%.3f' % ytr.mean(), 'val', xva.shape, 'pos=%.3f' % yva.mean())
    ds_tr = make_ds(xtr, ytr, a.batch, True, 7)
    ds_va = make_ds(xva, yva, 64, False)
    model.compile(optimizer=keras.optimizers.Adam(a.lr),
                  loss=keras.losses.SparseCategoricalCrossentropy(), metrics=['accuracy'])
    ck = os.path.join(a.out, 'v29_scene_best.keras')
    cbs = [keras.callbacks.ModelCheckpoint(ck, monitor='val_accuracy', save_best_only=True, verbose=1),
           keras.callbacks.CSVLogger(os.path.join(a.out, 'finetune_log.csv'))]
    model.fit(ds_tr, validation_data=ds_va, epochs=a.epochs, callbacks=cbs, verbose=2)
    best = keras.models.load_model(ck)
    v = best.evaluate(ds_va, verbose=0)
    print('SCENE val_loss=%.4f val_acc=%.4f' % (v[0], v[1]))
    json.dump({'scene_val_loss': float(v[0]), 'scene_val_acc': float(v[1]),
               'scene_train_n': int(len(ytr)), 'scene_val_n': int(len(yva))},
              open(os.path.join(a.out, 'finetune_result.json'), 'w'), indent=2)


if __name__ == '__main__':
    main()
