#!/usr/bin/env python3
"""export_day_scene.py - frames (byte-verbatim) + per-segment sheets + summary.

PNG pixel == raw serial byte (int8 two's complement of the network input).
No +128, no inversion: the frames are a training set, the consumer reads int8.
A viewer will look inverted; `value-128` gives the display-correct picture.
"""
import re
import statistics
import struct
from collections import defaultdict
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw

HERE = Path(__file__).resolve().parent
LOG = HERE / "log_v29_day_scene.log"
FRAMES = HERE / "frames"

RE_MARK = re.compile(r"MMT_MARK seg=(\w+) edge=(\w+) ms=(\d+) wall=(\S+)")
RE_STAT = re.compile(r"MMT_IMGSTAT f=(\d+) min=(-?\d+) max=(-?\d+) mean=(-?\d+) p=(-?\d+)")
RE_IMG = re.compile(r"MMT_IMG (\d\d) ([0-9a-fA-F]{192})")
RE_DEC = re.compile(r"MMT_DEC t=(\d+)")
RE_ALARM = re.compile(r"MMT_ALARM (start|end) ms=(\d+)(.*)")
RE_PP = re.compile(r"MMT_PP .*?mean_sensor=(\d+)")


def parse():
    marks, frames, alarms, pps = [], [], [], []
    cur_stat, rows = None, {}
    last_t = 0
    for raw in LOG.read_text(encoding="utf-8", errors="replace").splitlines():
        s = raw.split("\t", 1)[-1].strip()
        m = RE_MARK.search(s)
        if m:
            marks.append(dict(seg=m.group(1), edge=m.group(2), ms=int(m.group(3)),
                              wall=m.group(4)))
            continue
        m = RE_ALARM.search(s)
        if m:
            cause = "ir_solo" if "cause=ir_solo" in m.group(3) else (
                "fusion" if "cause=fusion" in m.group(3) else "")
            alarms.append(dict(kind=m.group(1), ms=int(m.group(2)), cause=cause))
            continue
        m = RE_PP.search(s)
        if m:
            pps.append((last_t, int(m.group(1))))
            continue
        m = RE_STAT.search(s)
        if m:
            cur_stat = dict(f=int(m.group(1)), p=int(m.group(5)), mean=int(m.group(4)),
                            t=last_t)
            rows = {}
            continue
        m = RE_IMG.search(s)
        if m and cur_stat is not None:
            rows[int(m.group(1))] = bytes.fromhex(m.group(2))
            if len(rows) == 96:
                arr = np.zeros((96, 96), np.uint8)
                for k in range(96):
                    arr[k, :] = np.frombuffer(rows[k], np.uint8)
                frames.append(dict(cur_stat, pixels=arr))
                cur_stat, rows = None, {}
            continue
        m = RE_DEC.search(s)
        if m:
            last_t = int(m.group(1))
    return marks, frames, alarms, pps


def segments(marks):
    """device_ms ranges per segment from START/END marks."""
    out = {}
    open_at = {}
    for m in marks:
        if m["edge"] == "START":
            open_at[m["seg"]] = m["ms"]
        elif m["edge"] == "END" and m["seg"] in open_at:
            out[m["seg"]] = (open_at.pop(m["seg"]), m["ms"])
    return out


def main():
    marks, frames, alarms, pps = parse()
    segs = segments(marks)
    FRAMES.mkdir(exist_ok=True)

    by_seg = defaultdict(list)
    for f in frames:
        seg = next((s for s, (a, b) in segs.items() if a <= f["t"] <= b), "X")
        by_seg[seg].append(f)

    for seg, items in by_seg.items():
        for f in items:
            Image.fromarray(f["pixels"], mode="L").save(
                FRAMES / ("%s_t%07d_p%d.png" % (seg, f["t"], f["p"])))

    sheets = []
    for seg in sorted(by_seg):
        items = sorted(by_seg[seg], key=lambda x: x["t"])
        for start in range(0, len(items), 60):
            chunk = items[start:start + 60]
            cols, cell, pad, lab = 10, 120, 4, 14
            rows_n = (len(chunk) + cols - 1) // cols
            W = cols * (cell + pad) + pad
            H = rows_n * (cell + pad + lab) + pad + 22
            sheet = Image.new("RGB", (W, H), "white")
            d = ImageDraw.Draw(sheet)
            d.text((pad, 4), "v29 DAY/NIGHT capture  seg=%s  page %d  (n=%d, bytes verbatim)"
                   % (seg, start // 60 + 1, len(chunk)), fill="black")
            for i, f in enumerate(chunk):
                x = pad + (i % cols) * (cell + pad)
                y = 22 + (i // cols) * (cell + pad + lab)
                sheet.paste(Image.fromarray(f["pixels"], mode="L").resize((cell, cell)),
                            (x, y))
                d.text((x, y + cell + 2), "t=%d p=%d" % (f["t"], f["p"]), fill="black")
            p = HERE / ("sheet_%s_p%d.png" % (seg, start // 60 + 1))
            sheet.save(p)
            sheets.append(p)

    # summary
    L = []
    A = L.append
    A("# v29 白天/夜间分段场景采集 summary\n")
    A("> 只陈述事实与数字；真值由看图判定，本文件不生成任何标签。\n")
    A("## 固件与条件\n")
    A("| 项 | 值 |")
    A("|---|---|")
    A("| 固件 | `tinyml_pdti8_v29_daycap.bin`，485,938 B，CRC32 `64FD6FC5`，"
      "SHA256 `05745F6CDBAC92E96BD7468EFFE1B8D69D77B4E4069093DCF5850153446F8B7B` |")
    A("| 位流 | `v7_MERGE15.bit`，2,825,877 B，SHA256 `74E205F84613F23C1DD8040E2CF31F032BBF524D3ED81022DE551D998613AF40` |")
    A("| 相机预设 | 编译为 DAY(gf=42)，开机实测 `mean_sensor≈27 < 60`，按规则改 **NIGHT(gf=63)** 重建后采集 |")
    A("| 导图 | `IMG_DUMP_EVERY=3`（采集专用），缩略图频率不变 |")
    A("| 像素 | **字节原样**：PNG 值 = 串口字节 = 网络输入的 int8 补码；看图会偏反相，`值−128` 为显示正确方向 |")
    A("")
    A("## 分段（墙钟 / 设备 ms）\n")
    A("| 段 | START 墙钟 | END 墙钟 | 设备 ms 区间 | 帧数 | mean_sensor 中位数 |")
    A("|---|---|---|---|---|---|")
    for seg in sorted(segs):
        a, b = segs[seg]
        st = next((m for m in marks if m["seg"] == seg and m["edge"] == "START"), None)
        en = next((m for m in marks if m["seg"] == seg and m["edge"] == "END"), None)
        vals = [v for t, v in pps if a <= t <= b]
        med = "%.0f" % statistics.median(vals) if vals else "—"
        A("| %s | %s | %s | %d–%d | %d | %s |"
          % (seg, st["wall"] if st else "—", en["wall"] if en else "—", a, b,
             len(by_seg.get(seg, [])), med))
    A("")
    A("## MMT_ALARM\n")
    if alarms:
        A("| # | 类型 | 设备 ms | cause |")
        A("|---|---|---|---|")
        for i, x in enumerate(alarms, 1):
            A("| %d | %s | %d | %s |" % (i, x["kind"], x["ms"], x["cause"] or "（旧格式，无 cause）"))
    else:
        A("无 MMT_ALARM 行。")
    A("")
    A("## 完整性\n")
    txt = LOG.read_text(encoding="utf-8", errors="replace")
    A("| 项 | 值 |")
    A("|---|---|")
    A("| 日志行数 | %d |" % len(txt.splitlines()))
    A("| 96×96 图组 | **%d** |" % len(frames))
    A("| GAP | %d |" % txt.count("### GAP"))
    A("| 串口重连 | %d |" % txt.count("### RECONNECTED"))
    (HERE / "summary.md").write_text("\n".join(L) + "\n", encoding="utf-8")

    print("frames=%d sheets=%d alarms=%d segs=%s"
          % (len(frames), len(sheets), len(alarms), sorted(segs)))
    for seg in sorted(by_seg):
        print("   %s: %d" % (seg, len(by_seg[seg])))


if __name__ == "__main__":
    main()
