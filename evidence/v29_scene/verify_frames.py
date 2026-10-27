#!/usr/bin/env python3
"""verify_frames.py - prove exported PNGs match the log hex byte-for-byte.

Picks 3 frames spread across the capture, re-reads their MMT_IMG hex from the log,
applies the documented rule (u = int8(byte) + 128), and compares against the PNG
that export_scene.py wrote.
"""
import re
from pathlib import Path

import numpy as np
from PIL import Image

HERE = Path(__file__).resolve().parent
LOG = HERE / "log_v29_scene.log"
FRAMES = HERE / "frames"

RE_STAT = re.compile(r"MMT_IMGSTAT f=(\d+) .*?stage=(\w+) t=(\d+) mean_sensor=(\d+)")
RE_IMG = re.compile(r"MMT_IMG (\d\d) ([0-9a-fA-F]{192})")


def collect():
    groups = []
    cur, rows = None, {}
    for raw in LOG.read_text(encoding="utf-8", errors="replace").splitlines():
        s = raw.split("\t", 1)[-1].strip()
        m = RE_STAT.search(s)
        if m:
            cur, rows = dict(stage=m.group(2), t=int(m.group(3))), {}
            continue
        m = RE_IMG.search(s)
        if m and cur is not None:
            rows[int(m.group(1))] = bytes.fromhex(m.group(2))
            if len(rows) == 96:
                a = np.zeros((96, 96), np.uint8)
                for k in range(96):
                    a[k, :] = np.frombuffer(rows[k], np.uint8)
                groups.append((cur, a))
                cur, rows = None, {}
    return groups


def main():
    groups = collect()
    picks = [groups[0], groups[len(groups) // 2], groups[-1]]
    ok_all = True
    print("%-8s %-9s %-22s %s" % ("肢体", "device_ms", "PNG", "结果"))
    for meta, raw in picks:
        png = FRAMES / ("%s_t%07d_p%d.png" % (meta["stage"], meta["t"], 0))
        cands = sorted(FRAMES.glob("%s_t%07d_p*.png" % (meta["stage"], meta["t"])))
        if not cands:
            print("  缺失 %s_t%07d" % (meta["stage"], meta["t"]))
            ok_all = False
            continue
        png = cands[0]
        expect = (raw.view(np.int8).astype(np.int16) + 128).astype(np.uint8)
        got = np.array(Image.open(png).convert("L"), np.uint8)
        same = np.array_equal(expect, got)
        ok_all &= same
        diff = int((expect != got).sum())
        print("%-8s %-9d %-22s %s (差异像素 %d)" %
              (meta["stage"], meta["t"], png.name, "逐字节一致" if same else "不一致", diff))
        # 同时证实「旧做法」会丢多少
        old = np.clip(raw.astype(np.int16) + 128, 0, 255).astype(np.uint8)
        lost = int((old != expect).sum())
        print("         旧做法 clip(b+128) 与正确值不同的像素: %d / 9216 (%.1f%%)"
              % (lost, lost / 9216 * 100))
    print()
    print("总体:", "全部一致" if ok_all else "存在不一致")
    return 0 if ok_all else 1


if __name__ == "__main__":
    raise SystemExit(main())
