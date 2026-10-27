#!/usr/bin/env python3
"""export_scene.py - export 96x96 frames + per-segment contact sheets from the v29 scene log.

Every MMT_IMGSTAT carries stage/t/p/mean_sensor/params, so segment and device time
come straight from the firmware. Only complete 96-row groups are exported (the log
contains one serial reconnect, which leaves a truncated group).
"""
import json
import re
from collections import defaultdict
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw

HERE = Path(__file__).resolve().parent
LOG = HERE / "log_v29_scene.log"
FRAMES = HERE / "frames"

RE_STAT = re.compile(
    r"MMT_IMGSTAT f=(\d+) min=(-?\d+) max=(-?\d+) mean=(-?\d+) p=(-?\d+) "
    r"stage=(\w+) t=(\d+) mean_sensor=(\d+) vts=(\d+) exp20=(\d+) gc=(\d+) gf=(\d+)")
RE_IMG = re.compile(r"MMT_IMG (\d\d) ([0-9a-fA-F]{192})")


def parse():
    frames, marks = [], []
    cur = None
    rows = {}
    for raw in LOG.read_text(encoding="utf-8", errors="replace").splitlines():
        s = raw.split("\t", 1)[-1].strip()
        if s.startswith("MMT_MARK"):
            m = dict(re.findall(r"(\w+)=([\w\.\-]+)", s))
            marks.append(m)
            continue
        m = RE_STAT.search(s)
        if m:
            cur = dict(f=int(m.group(1)), p=int(m.group(5)), stage=m.group(6),
                       t=int(m.group(7)), mean_sensor=int(m.group(8)),
                       vts=int(m.group(9)), exp20=int(m.group(10)),
                       gc=int(m.group(11)), gf=int(m.group(12)))
            rows = {}
            continue
        m = RE_IMG.search(s)
        if m and cur is not None:
            y = int(m.group(1))
            rows[y] = bytes.fromhex(m.group(2))
            if len(rows) == 96:
                arr = np.zeros((96, 96), np.uint8)
                for k in range(96):
                    arr[k, :] = np.frombuffer(rows[k], dtype=np.uint8)
                frames.append(dict(cur, pixels=arr))
                cur = None
                rows = {}
    return frames, marks


def main():
    frames, marks = parse()
    FRAMES.mkdir(exist_ok=True)
    by_seg = defaultdict(list)

    for f in frames:
        # 串口字节是 int8 的二进制补码；按 int8 解读后 +128 得到 0..255（模 256，不截断）
        img = (f["pixels"].view(np.int8).astype(np.int16) + 128).astype(np.uint8)
        name = "%s_t%07d_p%d.png" % (f["stage"], f["t"], f["p"])
        Image.fromarray(img, mode="L").save(FRAMES / name)
        by_seg[f["stage"]].append((f, img))

    # per-segment sheets, 60 per page
    sheets = []
    for seg in sorted(by_seg):
        items = sorted(by_seg[seg], key=lambda x: x[0]["t"])
        for start in range(0, len(items), 60):
            chunk = items[start:start + 60]
            cols, rows = 10, 6
            cell, pad, lab = 120, 4, 14
            W = cols * (cell + pad) + pad
            H = rows * (cell + pad + lab) + pad + 22
            sheet = Image.new("RGB", (W, H), "white")
            d = ImageDraw.Draw(sheet)
            d.text((pad, 4), "v29 scene  seg=%s  page %d  (n=%d)"
                   % (seg, start // 60 + 1, len(chunk)), fill="black")
            for i, (f, img) in enumerate(chunk):
                x = pad + (i % cols) * (cell + pad)
                y = 22 + (i // cols) * (cell + pad + lab) + (cell - cell) + 0
                y = 22 + (i // cols) * (cell + pad + lab)
                sheet.paste(Image.fromarray(img, mode="L").resize((cell, cell)),
                            (x, y))
                d.text((x, y + cell + 2), "t=%d p=%d" % (f["t"], f["p"]), fill="black")
            out = HERE / ("sheet_%s_p%d.png" % (seg, start // 60 + 1))
            sheet.save(out)
            sheets.append(out)

    meta = dict(
        frames=len(frames),
        per_segment={k: len(v) for k, v in sorted(by_seg.items())},
        sheets=[p.name for p in sheets],
        params=dict(vts=int(frames[0]["vts"]), exp20=int(frames[0]["exp20"]),
                    exp_half_lines=int(frames[0]["exp20"]) // 16,
                    gc=int(frames[0]["gc"]), gf=int(frames[0]["gf"])) if frames else {},
        marks=len(marks),
    )
    (HERE / "export_meta.json").write_text(
        json.dumps(meta, indent=2, ensure_ascii=False), encoding="utf-8")
    print(json.dumps(meta, indent=2, ensure_ascii=False))


if __name__ == "__main__":
    main()
