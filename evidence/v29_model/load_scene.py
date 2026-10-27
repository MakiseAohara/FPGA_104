# -*- coding: utf-8 -*-
"""加载场景标注数据（comms/scene_labels_existing）：
- 只用 label_intruder != -1 的样本，标签 = label_intruder（1=闯入者，0=无）
- 按 source_log 整段划分：含 v25_gate / v27_gate / v28_gate 的段 -> 验证；其余 -> 训练/微调
- 图是板上 0..255 字节，保存 uint8，训练时按 (u-128)/127.5 ≈ x/127.5-1 归一化
输出：scene_train_x/y.npy, scene_val_x/y.npy, source_map.json
"""
import argparse, csv, json, os
import numpy as np
from PIL import Image

VAL_KEYS = ('v25_gate', 'v27_gate', 'v28_gate')


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--labels', required=True)
    ap.add_argument('--out', required=True)
    a = ap.parse_args()
    root = os.path.dirname(a.labels)
    rows = list(csv.DictReader(open(a.labels, encoding='utf-8')))
    tr_x, tr_y, tr_src = [], [], []
    va_x, va_y, va_src = [], [], []
    for r in rows:
        lab = int(r['label_intruder'])
        if lab == -1:
            continue
        p = os.path.join(root, r['file'])
        if not os.path.exists(p):
            continue
        img = np.asarray(Image.open(p).convert('L'), dtype=np.uint8)
        if img.shape != (96, 96):
            img = np.asarray(Image.fromarray(img).resize((96, 96), Image.BILINEAR), dtype=np.uint8)
        is_val = any(k in r['source_log'] for k in VAL_KEYS)
        if is_val:
            va_x.append(img); va_y.append(lab); va_src.append(r['source_log'])
        else:
            tr_x.append(img); tr_y.append(lab); tr_src.append(r['source_log'])
    os.makedirs(a.out, exist_ok=True)
    np.save(os.path.join(a.out, 'scene_train_x.npy'), np.stack(tr_x))
    np.save(os.path.join(a.out, 'scene_train_y.npy'), np.asarray(tr_y, np.uint8))
    np.save(os.path.join(a.out, 'scene_val_x.npy'), np.stack(va_x))
    np.save(os.path.join(a.out, 'scene_val_y.npy'), np.asarray(va_y, np.uint8))
    json.dump({'train': {'n': len(tr_y), 'pos': float(np.mean(tr_y)) if tr_y else None,
                         'sources': {k: tr_src.count(k) for k in sorted(set(tr_src))}},
               'val': {'n': len(va_y), 'pos': float(np.mean(va_y)) if va_y else None,
                       'sources': {k: va_src.count(k) for k in sorted(set(va_src))}}},
              open(os.path.join(a.out, 'scene_split.json'), 'w'), indent=2, ensure_ascii=False)
    print('scene train', len(tr_y), 'pos=%.3f' % (np.mean(tr_y) if tr_y else -1))
    print('scene val  ', len(va_y), 'pos=%.3f' % (np.mean(va_y) if va_y else -1))
    print('val sources', sorted(set(va_src)))


if __name__ == '__main__':
    main()
