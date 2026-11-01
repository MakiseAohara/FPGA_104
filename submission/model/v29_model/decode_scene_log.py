# -*- coding: utf-8 -*-
"""从原始串口日志解码 v29_scene 帧（不使用任何 PNG），并做旧模型自检。

- 解析规则与 evidence/v29_scene/export_scene.py 的 parse() 一致：MMT_IMGSTAT 开新帧，
  MMT_IMG 96 行十六进制，每行 96 字节
- 像素 = 十六进制字节原样 uint8(u)（不 +128、不做 int8 转换）
- 自检：旧模型输入 q = u.view(int8)（字节原样位重解释），输出 person 概率与日志 p 比较
"""
import argparse, csv, json, os, re, sys
import numpy as np
import tensorflow as tf

RE_STAT = re.compile(
    r"MMT_IMGSTAT f=(\d+) min=(-?\d+) max=(-?\d+) mean=(-?\d+) p=(-?\d+) "
    r"stage=(\w+) t=(\d+) mean_sensor=(\d+) vts=(\d+) exp20=(\d+) gc=(\d+) gf=(\d+)")
RE_IMG = re.compile(r"MMT_IMG (\d\d) ([0-9a-fA-F]{192})")


def parse_log(path):
    frames = []
    cur, rows = None, {}
    with open(path, 'r', encoding='utf-8', errors='replace') as f:
        for raw in f:
            s = raw.split('\t', 1)[-1].strip()
            m = RE_STAT.search(s)
            if m:
                cur = dict(f=int(m.group(1)), p=int(m.group(5)), stage=m.group(6),
                           t=int(m.group(7)), mean_sensor=int(m.group(8)))
                rows = {}
                continue
            m = RE_IMG.search(s)
            if m and cur is not None:
                rows[int(m.group(1))] = bytes.fromhex(m.group(2))
                if len(rows) == 96:
                    arr = np.zeros((96, 96), np.uint8)
                    for k in range(96):
                        arr[k, :] = np.frombuffer(rows[k], dtype=np.uint8)
                    frames.append(dict(cur, pixels=arr))
                    cur, rows = None, {}
    return frames


def load_old_model(path):
    it = tf.lite.Interpreter(model_path=path)
    it.allocate_tensors()
    return it


def infer_old(it, imgs_u8):
    ind = it.get_input_details()[0]; outd = it.get_output_details()[0]
    osc, ozp = outd['quantization']
    qs = []
    for u in imgs_u8:
        q = u.view(np.int8)          # 字节原样位重解释
        it.set_tensor(ind['index'], q[None, :, :, None]); it.invoke()
        o = it.get_tensor(outd['index'])[0]
        qs.append(int(o[1]))
    return np.array(qs)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--log', required=True)
    ap.add_argument('--old-model', required=True)
    ap.add_argument('--labels', required=True)
    ap.add_argument('--out', required=True)
    a = ap.parse_args()
    frames = parse_log(a.log)
    print('parsed frames:', len(frames))
    by_key = {(f['stage'], f['t']): f for f in frames}

    rows = list(csv.DictReader(open(a.labels, encoding='utf-8')))
    matched, missing = [], []
    for r in rows:
        m = re.match(r'([A-F])_t(\d+)_p(-?\d+)\.png', r['file'])
        if not m:
            continue
        key = (m.group(1), int(m.group(2)))
        if key in by_key:
            matched.append((r, by_key[key]))
        else:
            missing.append(r['file'])
    print('labels:', len(rows), 'matched:', len(matched), 'missing:', len(missing))

    it = load_old_model(a.old_model)
    imgs = [f['pixels'] for _, f in matched]
    q_old = infer_old(it, imgs)
    p_log = np.array([f['p'] for _, f in matched])
    corr = float(np.corrcoef(q_old, p_log)[0, 1])
    diff = q_old - p_log
    within2 = float((np.abs(diff) <= 2).mean())
    print('corr(q_old_u_view_int8, p_log) = %.4f' % corr)
    print('mean|diff| = %.3f  max|diff| = %d  frac<=2 = %.3f' % (np.abs(diff).mean(), np.abs(diff).max(), within2))
    # 对照：u-128 口径
    def infer_sub128(it, imgs):
        ind = it.get_input_details()[0]; outd = it.get_output_details()[0]
        qs = []
        for u in imgs:
            q = np.clip(u.astype(np.int16) - 128, -128, 127).astype(np.int8)
            it.set_tensor(ind['index'], q[None, :, :, None]); it.invoke()
            qs.append(int(it.get_tensor(outd['index'])[0][1]))
        return np.array(qs)
    q2 = infer_sub128(it, imgs)
    print('corr(q_old_u_minus_128, p_log) = %.4f' % float(np.corrcoef(q2, p_log)[0, 1]))

    res = {'frames': len(frames), 'matched': len(matched), 'missing': len(missing),
           'corr_bitreinterpret': corr, 'mean_abs_diff': float(np.abs(diff).mean()),
           'max_abs_diff': int(np.abs(diff).max()), 'frac_le2': within2,
           'corr_sub128': float(np.corrcoef(q2, p_log)[0, 1])}
    json.dump(res, open(a.out, 'w'), indent=2)
    print('saved', a.out)


if __name__ == '__main__':
    main()
