# -*- coding: utf-8 -*-
"""COCO parquet -> 96x96（板上 v28 固件预处理：crop1 + 3x3x2x2 采样 + 1%/99% 拉伸）
标签：person 框与 crop 区域重叠面积 / 1080^2 >= 0.5%
"""
import os, sys, glob, io
import numpy as np
from PIL import Image
import pyarrow.parquet as pq

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from board_preprocess import board_sample_src, person_ratio_crop

SRC = r'D:\FPGA\mmt\work_v29\data\coco'
OUT = r'D:\FPGA\mmt\work_v29\data\vww96_board'


def main():
    os.makedirs(OUT, exist_ok=True)
    groups = {'train': ([], []), 'val': ([], [])}
    for fp in sorted(glob.glob(os.path.join(SRC, '*.parquet'))):
        base = os.path.basename(fp)
        grp = 'train' if base.startswith('train') else 'val'
        if os.path.getsize(fp) < 1_000_000:
            print('skip small', base); continue
        try:
            pf = pq.ParquetFile(fp)
        except Exception as e:
            print('skip bad', base, str(e)[:50]); continue
        xs, ys = groups[grp]
        n0 = len(xs)
        try:
            for batch in pf.iter_batches(batch_size=64):
                d = batch.to_pydict()
                for i, im in enumerate(d['image']):
                    raw = im.get('bytes') if isinstance(im, dict) else im
                    if raw is None:
                        continue
                    try:
                        img = Image.open(io.BytesIO(raw)); img.load()
                    except Exception:
                        continue
                    W, H = img.size
                    lab = 1 if person_ratio_crop(d['objects'][i], W, H) >= 0.005 else 0
                    g = np.asarray(img.convert('L'), dtype=np.uint8)
                    xs.append(board_sample_src(g)); ys.append(lab)
        except Exception as e:
            print('iter break', base, str(e)[:50])
        print(base, grp, len(xs) - n0, 'pos', int(sum(ys)))
    for grp, (xs, ys) in groups.items():
        if not xs:
            continue
        X = np.stack(xs); Y = np.asarray(ys, np.uint8)
        np.save(os.path.join(OUT, grp + '_x.npy'), X)
        np.save(os.path.join(OUT, grp + '_y.npy'), Y)
        print('saved', grp, X.shape, 'pos=%.3f' % Y.mean())


if __name__ == '__main__':
    main()
