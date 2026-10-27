# -*- coding: utf-8 -*-
"""新旧模型对比（旧模型用板上 frames.csv 记录的 int8 分数，新模型用 tflite 推理）
输出：val 集（新模型）准确率；v27 板上 10 帧的新旧分数表。
"""
import argparse, csv, json, os
import numpy as np
from PIL import Image
import tensorflow as tf

def load(path):
    it = tf.lite.Interpreter(model_path=path)
    it.allocate_tensors()
    return it

def infer(it, imgs, mode):
    ind = it.get_input_details()[0]; outd = it.get_output_details()[0]
    sc, zp = ind['quantization']; os_, ozp = outd['quantization']
    out = []
    for img in imgs:
        x = img.astype(np.float32)
        if mode == 'normal':
            q = np.clip(np.round((x/127.5-1.0)/sc) + zp, -128, 127).astype(np.int8)
        else:
            # 固件 INPUT_SUB128=1：像素 u -> (int8)(u-128)
            q = np.clip(x.astype(np.int16) - 128, -128, 127).astype(np.int8)
        it.set_tensor(ind['index'], q[None,:,:,None]); it.invoke()
        o = it.get_tensor(outd['index'])[0]
        out.append(((float(o[1]) - ozp) * os_, int(o[1])))
    return out

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--data', required=True)
    ap.add_argument('--new', required=True)
    ap.add_argument('--frames', required=True)
    ap.add_argument('--out', required=True)
    a = ap.parse_args()
    os.makedirs(a.out, exist_ok=True)

    # 1) val 集（新模型）
    xva = np.load(os.path.join(a.data, 'val_x.npy')); yva = np.load(os.path.join(a.data, 'val_y.npy'))
    sub = np.random.RandomState(0).choice(len(xva), 3000, replace=False)
    it = load(a.new)
    for mode in ('normal','board'):
        r = infer(it, xva[sub], mode)
        s = np.array([v[0] for v in r]); acc = float(((s>=0.5).astype(int)==yva[sub]).mean())
        order=np.argsort(-s); ys=yva[sub][order]
        tpr=np.cumsum(ys)/max(ys.sum(),1); fpr=np.cumsum(1-ys)/max((1-ys).sum(),1)
        auc=float(np.trapz(tpr,fpr))
        print('new %s val_acc@0.5=%.4f auc=%.4f pos_mean=%.3f neg_mean=%.3f' % (mode,acc,auc,s[yva[sub]==1].mean(),s[yva[sub]==0].mean()))

    # 2) v27 帧：旧分数来自 frames.csv(p)，新模型推理
    fr = []
    with open(os.path.join(a.frames,'frames.csv'), newline='', encoding='utf-8') as f:
        for row in csv.DictReader(f): fr.append(row)
    imgs = [np.asarray(Image.open(os.path.join(a.frames, r['file'])).convert('L'), dtype=np.uint8) for r in fr]
    newn = infer(it, imgs, 'normal'); newb = infer(it, imgs, 'board')
    rows = []
    for i, r in enumerate(fr):
        rows.append({'file': os.path.basename(r['file']), 'old_p_int8': int(r['p']),
                     'old_p_float': (int(r['p'])+128)/256.0,
                     'new_p_normal': newn[i][0], 'new_q_normal': newn[i][1],
                     'new_p_board': newb[i][0], 'new_q_board': newb[i][1]})
    json.dump(rows, open(os.path.join(a.out,'board_frames_compare.json'),'w'), indent=2, ensure_ascii=False)
    with open(os.path.join(a.out,'board_frames_compare.csv'),'w',newline='',encoding='utf-8') as f:
        w=csv.DictWriter(f, fieldnames=list(rows[0].keys())); w.writeheader(); [w.writerow(r) for r in rows]
    print('\n| frame | old p(int8) | old p | new normal | new board |')
    print('|---|---|---|---|---|')
    for r in rows:
        print('| %s | %d | %.3f | %.3f | %.3f |' % (r['file'], r['old_p_int8'], r['old_p_float'], r['new_p_normal'], r['new_p_board']))

if __name__ == '__main__':
    main()

