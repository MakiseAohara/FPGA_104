# -*- coding: utf-8 -*-
"""板上预处理（v28 固件 evidence/v28_fw/preprocess_core.h）的 numpy 复现。

配置（与固件一致）：
  CROP_MODE = 1   中间正方形 (1920x1080 -> x0=420, cw=ch=1080)
  STRETCH_ON = 1  1%/99% 分位线性拉伸到 0..255
  NORM_ON = 0     不做亮度归一化
  PP_BOX = 3      每输出像素 3x3 个采样盒，每盒 2x2 quad mean
输出 96x96 uint8；固件随后 (INPUT_SUB128=1) 做 (int8)(u-128)。
"""
import numpy as np

FRAME_W, FRAME_H = 1920, 1080
OUT_W = OUT_H = 96
BOX = 3
STRETCH_LO_PM = 10    # 1%
STRETCH_HI_PM = 990   # 99%


def _hist_percentile(hist, total, permille):
    """与 pp_hist_percentile 一致：累加直方图到 >= total*permille/1000"""
    target = (total * permille) // 1000
    cum = 0
    for i in range(256):
        cum += hist[i]
        if cum >= target:
            return i
    return 255


def stretch(img96):
    """对 96x96 uint8 做 1%/99% 分位拉伸（固件逻辑）"""
    flat = img96.reshape(-1).astype(np.uint8)
    hist = np.bincount(flat, minlength=256)
    total = flat.size
    lo = _hist_percentile(hist, total, STRETCH_LO_PM)
    hi = _hist_percentile(hist, total, STRETCH_HI_PM)
    if hi > lo:
        span = hi - lo
        out = (img96.astype(np.int32) - lo) * 255 // span
        return np.clip(out, 0, 255).astype(np.uint8)
    return img96.copy()


def board_sample(frames_1920x1080):
    """输入 uint8 (H=1080,W=1920) 或 (N,1080,1920)，输出 (N,96,96) uint8（crop + 3x3x(2x2) 均值 + stretch）。

    坐标公式严格按 preprocess_core.h:
      sy = ((oy*BOX + j) * ch) / (OUT_H*BOX) + y0 ; sy &= ~1
      sx = ((ox*BOX + i) * cw) / (OUT_W*BOX) + x0 ; sx &= ~1
      quad_mean(a,b,c,d) = (a+b+c+d)>>2，取 (sx,sy),(sx+1,sy),(sx,sy+1),(sx+1,sy+1)
    """
    arr = np.asarray(frames_1920x1080)
    single = arr.ndim == 2
    if single:
        arr = arr[None]
    n = arr.shape[0]
    x0 = (FRAME_W - 1080) // 2
    y0 = 0
    cw = ch = 1080
    out = np.zeros((n, OUT_H, OUT_W), dtype=np.uint8)
    # 预计算采样坐标
    sy_idx = np.zeros((OUT_H, BOX), dtype=np.int32)
    sx_idx = np.zeros((OUT_W, BOX), dtype=np.int32)
    for oy in range(OUT_H):
        for j in range(BOX):
            sy = ((oy * BOX + j) * ch) // (OUT_H * BOX) + y0
            sy &= ~1
            if sy > y0 + ch - 2:
                sy = y0 + ch - 2
            sy_idx[oy, j] = sy
    for ox in range(OUT_W):
        for i in range(BOX):
            sx = ((ox * BOX + i) * cw) // (OUT_W * BOX) + x0
            sx &= ~1
            if sx > x0 + cw - 2:
                sx = x0 + cw - 2
            sx_idx[ox, i] = sx
    for k in range(n):
        f = arr[k]
        acc = np.zeros((OUT_H, OUT_W), dtype=np.uint32)
        for j in range(BOX):
            for i in range(BOX):
                ys = sy_idx[:, j][:, None]      # (OUT_H,1)
                xs = sx_idx[:, i][None, :]      # (1,OUT_W)
                q = (f[ys, xs].astype(np.uint32) + f[ys + 1, xs].astype(np.uint32) +
                     f[ys, xs + 1].astype(np.uint32) + f[ys + 1, xs + 1].astype(np.uint32)) >> 2
                acc += q
        raw = (acc // (BOX * BOX)).astype(np.uint8)
        out[k] = stretch(raw)
    return out[0] if single else out


def person_ratio_crop(objects, W, H):
    """按 crop 区域（1920x1080 画面的中间 1080x1080）计算 person 面积占比。"""
    if not objects or W <= 0 or H <= 0:
        return 0.0
    cats = objects.get('category')
    bboxes = objects.get('bbox')
    if cats is None or bboxes is None:
        return 0.0
    sx = FRAME_W / float(W)
    sy = FRAME_H / float(H)
    cx0, cx1 = (FRAME_W - 1080) // 2, (FRAME_W + 1080) // 2
    cy0, cy1 = 0, 1080
    best = 0.0
    for c, bb in zip(cats, bboxes):
        is_person = (str(c).lower() == 'person')
        try:
            if isinstance(c, (int, np.integer)) and int(c) == 0:
                is_person = True
        except Exception:
            pass
        if not is_person:
            continue
        try:
            if isinstance(bb, dict):
                x, y, w, h = float(bb['x']), float(bb['y']), float(bb['w']), float(bb['h'])
            else:
                x, y, w, h = [float(v) for v in bb]
        except Exception:
            continue
        x1, y1 = x * sx, y * sy
        x2, y2 = (x + w) * sx, (y + h) * sy
        ix = max(0.0, min(x2, cx1) - max(x1, cx0))
        iy = max(0.0, min(y2, cy1) - max(y1, cy0))
        r = (ix * iy) / float(1080 * 1080)
        if r > best:
            best = r
    return best


if __name__ == '__main__':
    # 自检：用合成图验证几何与拉伸
    yy, xx = np.mgrid[0:FRAME_H, 0:FRAME_W]
    img = (xx * 255 // (FRAME_W - 1)).astype(np.uint8)  # 横向渐变
    out = board_sample(img)
    print('out shape', out.shape, 'dtype', out.dtype, 'min/max/mean', out.min(), out.max(), int(out.mean()))
    print('row0 first8', out[0, :8].tolist())
    print('col-wise monotonic', bool(np.all(np.diff(out[0].astype(int)) >= 0)))
    # 常量图：拉伸后应仍是常量
    flat = np.full((FRAME_H, FRAME_W), 77, np.uint8)
    o2 = board_sample(flat)
    print('flat unique', np.unique(o2).tolist())
    # bbox 裁剪判定
    objs = {'category': [0], 'bbox': [[0, 0, 100, 100]], 'area': [10000]}
    print('person at left edge ratio', person_ratio_crop(objs, 640, 480))

def board_sample_src(img, stretch_on=True):
    """直接在任意尺寸原图上按比例采样（等价于先 nearest-resize 到 1920x1080 再 board_sample），快 3-5 倍。"""
    a = np.asarray(img)
    H, W = a.shape[:2]
    x0 = (FRAME_W - 1080) // 2
    y0 = 0
    cw = ch = 1080
    out = np.zeros((OUT_H, OUT_W), dtype=np.uint8)
    acc = np.zeros((OUT_H, OUT_W), dtype=np.uint32)
    for j in range(BOX):
        sy_f = ((np.arange(OUT_H) * BOX + j) * ch) // (OUT_H * BOX) + y0
        sy_f &= ~1
        sy_f = np.minimum(sy_f, y0 + ch - 2)
        y_src = np.minimum((sy_f * H / FRAME_H).astype(np.int32), H - 2)
        for i in range(BOX):
            sx_f = ((np.arange(OUT_W) * BOX + i) * cw) // (OUT_W * BOX) + x0
            sx_f &= ~1
            sx_f = np.minimum(sx_f, x0 + cw - 2)
            x_src = np.minimum((sx_f * W / FRAME_W).astype(np.int32), W - 2)
            ys = y_src[:, None]; xs = x_src[None, :]
            q = (a[ys, xs].astype(np.uint32) + a[ys + 1, xs].astype(np.uint32) +
                 a[ys, xs + 1].astype(np.uint32) + a[ys + 1, xs + 1].astype(np.uint32)) >> 2
            acc += q
    raw = (acc // (BOX * BOX)).astype(np.uint8)
    return stretch(raw) if stretch_on else raw
