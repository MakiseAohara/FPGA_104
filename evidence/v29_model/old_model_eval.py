# -*- coding: utf-8 -*-
"""修补旧模型 person_detect.tflite 的 quantized_dimension（越界 3 -> 0），
再用 TF 2.16 在 v29_scene D/E/F 上跑两种输入的 AUC：
  A) 位重解释：q = (int8)u
  B) u-128    ：q = clip(u-128, -128, 127)
"""
import argparse, csv, json, os, struct, sys
import numpy as np
from PIL import Image

FT = {0: 'FLOAT32', 1: 'FLOAT16', 2: 'INT32', 3: 'UINT8', 4: 'INT64', 5: 'STRING', 6: 'BOOL',
      7: 'INT16', 8: 'COMPLEX64', 9: 'INT8', 10: 'FLOAT64'}


def u32(b, p): return struct.unpack_from('<I', b, p)[0]
def i32(b, p): return struct.unpack_from('<i', b, p)[0]
def u16(b, p): return struct.unpack_from('<H', b, p)[0]


def vt(b, t): return t - i32(b, t)


def foff(b, t, fid):
    v = vt(b, t); s = u16(b, v); p = 4 + fid * 2
    if p + 2 > s: return None
    o = u16(b, v + p)
    return None if o == 0 else t + o


def fvec(b, t, fid):
    o = foff(b, t, fid)
    if o is None: return None, 0
    v = o + u32(b, o)
    return v, u32(b, v)


def table_at(b, vec, i):
    e = vec + 4 + i * 4
    return e + u32(b, e)


def patch(src, dst):
    b = bytearray(open(src, 'rb').read())
    m = u32(b, 0)
    svec, sn = fvec(b, m, 2)
    sg = table_at(b, svec, 0)
    tvec, tn = fvec(b, sg, 0)
    fixed = 0
    for i in range(tn):
        tt = table_at(b, tvec, i)
        shv, shn = fvec(b, tt, 0)
        qpos = foff(b, tt, 4)
        if qpos is None: continue
        off = u32(b, qpos)
        if off == 0:
            continue
        qt = qpos + off
        qd = foff(b, qt, 6)
        if qd is None: continue
        val = struct.unpack_from('<i', b, qd)[0]
        if shn == 0 or val >= shn:
            struct.pack_into('<i', b, qd, 0); fixed += 1
    open(dst, 'wb').write(bytes(b))
    return fixed


def auc_score(s, y):
    order = np.argsort(-s); ys = y[order]
    tpr = np.cumsum(ys) / max(ys.sum(), 1); fpr = np.cumsum(1 - ys) / max((1 - ys).sum(), 1)
    return float(np.trapz(tpr, fpr))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--old', required=True)
    ap.add_argument('--patched', required=True)
    ap.add_argument('--frames', required=True)
    ap.add_argument('--labels', required=True)
    ap.add_argument('--out', required=True)
    a = ap.parse_args()
    n = patch(a.old, a.patched)
    print('patched quantized_dimension fields:', n)
    import tensorflow as tf
    it = tf.lite.Interpreter(model_path=a.patched); it.allocate_tensors()
    ind = it.get_input_details()[0]; outd = it.get_output_details()[0]
    osc, ozp = outd['quantization']
    rows = [r for r in csv.DictReader(open(a.labels, encoding='utf-8'))
            if r['segment'] in ('D', 'E', 'F') and r['label_intruder'] != '-1']
    imgs = []; ys = []; segs = []
    for r in rows:
        p = os.path.join(a.frames, r['file'])
        if not os.path.exists(p): continue
        im = np.asarray(Image.open(p).convert('L'), dtype=np.uint8)
        imgs.append(im); ys.append(int(r['label_intruder'])); segs.append(r['segment'])
    y = np.array(ys); segs = np.array(segs)
    res = {}
    for mode in ('bitreinterpret', 'sub128'):
        ps = []
        for im in imgs:
            if mode == 'bitreinterpret':
                q = im.astype(np.int8)
            else:
                q = np.clip(im.astype(np.int16) - 128, -128, 127).astype(np.int8)
            it.set_tensor(ind['index'], q[None, :, :, None]); it.invoke()
            o = it.get_tensor(outd['index'])[0]
            ps.append((float(o[1]) - ozp) * osc)
        ps = np.array(ps)
        res[mode] = {'n': int(len(y)), 'auc_all': auc_score(ps, y), 'acc@0.5': float(((ps >= 0.5).astype(int) == y).mean()),
                     'pos_med': float(np.median(ps[y == 1])), 'neg_med': float(np.median(ps[y == 0]))}
        for s in ('D', 'E', 'F'):
            m = segs == s
            if m.sum() > 0 and len(set(y[m])) > 1:
                res[mode]['auc_' + s] = auc_score(ps[m], y[m])
        print(mode, res[mode])
    os.makedirs(os.path.dirname(a.out), exist_ok=True)
    json.dump(res, open(a.out, 'w'), indent=2)
    print('saved', a.out)


if __name__ == '__main__':
    main()


