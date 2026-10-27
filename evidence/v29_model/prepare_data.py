# -*- coding: utf-8 -*-
"""COCO parquet -> 96x96 灰度 npy（Visual Wake Words 口径：person 框面积 >= 0.5% 为正样本）

用法：
  python prepare_data.py --parquet-dir D:\FPGA\mmt\work_v29\data\coco --out D:\FPGA\mmt\work_v29\data\vww96
自适应 schema：支持 objects.category 为字符串或 int（person=1）。
"""
import argparse, glob, io, json, os, sys
import numpy as np

def _parquet_ok(path):
    try:
        if os.path.getsize(path) < 1024*1024:
            return False
        with open(path,'rb') as f:
            h=f.read(4); f.seek(-4,2); t=f.read(4)
        return h==b'PAR1' and t==b'PAR1'
    except Exception:
        return False

def person_ratio(objects, img_w, img_h):
    """返回图中 person 框的最大面积占比；无 person 返回 0"""
    if objects is None:
        return 0.0
    best = 0.0
    # 规范化成列表字典
    if isinstance(objects, dict):
        cats = objects.get('category', objects.get('categories', None))
        bboxes = objects.get('bbox', None)
        if cats is None or bboxes is None:
            return 0.0
        n = len(bboxes)
        for i in range(n):
            c = cats[i]
            name = str(c).lower()
            if not (name == 'person' or name == '0'):
                if not (isinstance(c, (int, np.integer)) and int(c) == 0):
                    continue
            bb = bboxes[i]
            try:
                if isinstance(bb, dict):
                    x, y, w, h = float(bb['x']), float(bb['y']), float(bb['w']), float(bb['h'])
                else:
                    x, y, w, h = [float(v) for v in bb]
            except Exception:
                continue
            r = (w * h) / float(img_w * img_h) if img_w and img_h else 0.0
            if r > best:
                best = r
    return best

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--parquet-dir', required=True)
    ap.add_argument('--out', required=True)
    ap.add_argument('--limit', type=int, default=0)
    ap.add_argument('--crop-square', action='store_true', help='模拟板上 CROP_MODE=1：先取中间正方形再 resize')
    args = ap.parse_args()
    import pyarrow.parquet as pq
    from PIL import Image

    files = sorted(glob.glob(os.path.join(args.parquet_dir, '*.parquet')))
    print('parquet files:', len(files))
    os.makedirs(args.out, exist_ok=True)

    groups = {'train': ([], []), 'val': ([], [])}
    schema_printed = False
    counts = {'train': 0, 'val': 0}
    for fp in files:
        if not _parquet_ok(fp):
            print('  skip incomplete', os.path.basename(fp)); continue
        base = os.path.basename(fp)
        grp = 'train' if base.startswith('train') else 'val'
        pf = pq.ParquetFile(fp)
        if not schema_printed:
            print('schema:', pf.schema_arrow)
            schema_printed = True
        xs, ys = groups[grp]
        for batch in pf.iter_batches(batch_size=128):
            d = batch.to_pydict()
            imgcol = d.get('image')
            objcol = d.get('objects')
            for i in range(len(imgcol)):
                im = imgcol[i]
                if im is None:
                    continue
                raw = im.get('bytes') if isinstance(im, dict) else im
                if raw is None:
                    continue
                try:
                    img = Image.open(io.BytesIO(raw))
                    img.load()
                except Exception:
                    continue
                W, H = img.size
                ratio = person_ratio(objcol[i] if objcol is not None else None, W, H)
                lab = 1 if ratio >= 0.005 else 0
                g = img.convert('L')
                if args.crop_square and W > H:
                    x0 = (W - H) // 2
                    g = g.crop((x0, 0, x0 + H, H))
                elif args.crop_square and H > W:
                    y0 = (H - W) // 2
                    g = g.crop((0, y0, W, y0 + W))
                g = g.resize((96, 96), Image.BILINEAR)
                xs.append(np.asarray(g, dtype=np.uint8))
                ys.append(lab)
                if args.limit and len(xs) >= args.limit:
                    break
            if args.limit and len(xs) >= args.limit:
                break
        print('  %s [%s] -> total %d (pos %d)' % (base, grp, len(xs), int(sum(ys))))
        counts[grp] = len(xs)

    for grp, (xs, ys) in groups.items():
        if not xs:
            print('WARN: group %s empty' % grp)
            continue
        X = np.stack(xs, axis=0)
        Y = np.asarray(ys, dtype=np.uint8)
        np.save(os.path.join(args.out, grp + '_x.npy'), X)
        np.save(os.path.join(args.out, grp + '_y.npy'), Y)
        print('saved', grp, X.shape, 'pos=%.3f' % (Y.mean() if len(Y) else -1))

if __name__ == '__main__':
    main()


