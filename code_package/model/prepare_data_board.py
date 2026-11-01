# -*- coding: utf-8 -*-
"""COCO parquet -> 96x96（严格按板上 v28 固件预处理：crop1 + 3x3x2x2 采样 + 1%/99% 拉伸）
标签：person 框与 crop 区域（1920x1080 画面中间 1080x1080）的重叠面积 / 1080^2 >= 0.5%
"""
import argparse, glob, io, os
import numpy as np
from PIL import Image
import sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from board_preprocess import board_sample_src, person_ratio_crop, FRAME_W, FRAME_H


def parquet_ok(path):
    try:
        if os.path.getsize(path) < 1024 * 1024:
            return False
        with open(path, 'rb') as f:
            h = f.read(4); f.seek(-4, 2); t = f.read(4)
        return h == b'PAR1' and t == b'PAR1'
    except Exception:
        return False


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--parquet-dir', required=True)
    ap.add_argument('--out', required=True)
    ap.add_argument('--limit-train', type=int, default=0)
    args = ap.parse_args()
    import pyarrow.parquet as pq

    files = sorted(glob.glob(os.path.join(args.parquet_dir, '*.parquet')))
    groups = {'train': ([], []), 'val': ([], [])}
    for fp in files:
        if not parquet_ok(fp):
            print('  skip incomplete', os.path.basename(fp)); continue
        base = os.path.basename(fp)
        grp = 'train' if base.startswith('train') else 'val'
        xs, ys = groups[grp]
        try:
            pf = pq.ParquetFile(fp)
            pf.metadata.num_rows
        except Exception as e:
            print('  skip corrupt', os.path.basename(fp), str(e)[:40]); continue
        try:
            it = pf.iter_batches(batch_size=64)
        except Exception as e:
            print('  skip corrupt(it)', os.path.basename(fp), str(e)[:40]); continue
        _it = it
        while True:
          try:
            batch = next(_it)
          except StopIteration:
            break
          except Exception as e:
            print("  skip corrupt(iter)", os.path.basename(fp), str(e)[:40]); break
            d = batch.to_pydict()
            imgcol, objcol = d.get('image'), d.get('objects')
            for i in range(len(imgcol)):
                im = imgcol[i]
                raw = im.get('bytes') if isinstance(im, dict) else im
                if raw is None:
                    continue
                try:
                    img = Image.open(io.BytesIO(raw)); img.load()
                except Exception:
                    continue
                W, H = img.size
                ratio = person_ratio_crop(objcol[i] if objcol else None, W, H)
                lab = 1 if ratio >= 0.005 else 0
                g = np.asarray(img.convert('L'), dtype=np.uint8)
                xs.append(board_sample_src(g))
                ys.append(lab)
                if args.limit_train and len(xs) >= args.limit_train:
                    break
            if args.limit_train and len(xs) >= args.limit_train:
                break
        print('  %s [%s] -> %d (pos %d)' % (base, grp, len(xs), int(sum(ys))))
        if args.limit_train and len(xs) >= args.limit_train:
            break

    os.makedirs(args.out, exist_ok=True)
    for grp, (xs, ys) in groups.items():
        if not xs:
            continue
        X = np.stack(xs); Y = np.asarray(ys, dtype=np.uint8)
        np.save(os.path.join(args.out, grp + '_x.npy'), X)
        np.save(os.path.join(args.out, grp + '_y.npy'), Y)
        print('saved', grp, X.shape, 'pos=%.3f' % Y.mean())


if __name__ == '__main__':
    main()




