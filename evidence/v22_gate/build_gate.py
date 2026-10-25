#!/usr/bin/env python3
"""build_gate.py - ticks.csv / contact sheets / summary.md for the v22 gate run."""
import csv
import re
import statistics
from pathlib import Path

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np

HERE = Path(__file__).resolve().parent
LOG = HERE / "log_v22_gate.log"

RE_DEC = re.compile(r"MMT_DEC t=(\d+).*?alarm_req=(\d+).*?motion=(\d+)"
                    r".*?area=(\d+).*?person=(-?\d+)")
RE_OSD = re.compile(r"MMT_OSD .*?\bp=(-?\d+)")
RE_LP = re.compile(r"MMT_LP .*?lowpwr=(\d+).*?paused=(\d+)")
RE_PP = re.compile(r"MMT_PP .*?mean_sensor=(\d+)")
RE_IMGSTAT = re.compile(r"MMT_IMGSTAT f=(\d+).*?\bp=(-?\d+)")
RE_IMG = re.compile(r"MMT_IMG (\d\d) ([0-9a-f]{192})")
RE_LPEN = re.compile(r"MMT_LP_ENTER f=(\d+).*?ms=(\d+)")
RE_LPEX = re.compile(r"MMT_LP_EXIT f=(\d+).*?ms=(\d+)")
RE_ALARM = re.compile(r"MMT_ALARM (start|end) ms=(\d+)")


def main():
    lines = LOG.read_text(encoding="utf-8", errors="replace").splitlines()
    dec, pps, imgs, lps, alarms, boot = [], [], [], [], [], []
    lp_state = 0
    pending_p = None
    last_t = 0
    cur_img = None
    cur_stat = None

    for raw in lines:
        s = raw.split("\t", 1)[-1].strip()
        for tag in ("MMT_LIVE_BOOT", "MMT_CFG", "MMT_CAM "):
            if s.startswith(tag):
                boot.append(s)
        m = RE_ALARM.search(s)
        if m:
            alarms.append((m.group(1), int(m.group(2))))
            continue
        m = RE_LPEN.search(s)
        if m:
            lps.append(("enter", int(m.group(2))))
            continue
        m = RE_LPEX.search(s)
        if m:
            lps.append(("exit", int(m.group(2))))
            continue
        m = RE_OSD.search(s)
        if m:
            pending_p = int(m.group(1))
            continue
        m = RE_PP.search(s)
        if m:
            pps.append((last_t, int(m.group(1))))
            continue
        m = RE_IMGSTAT.search(s)
        if m:
            cur_stat = (last_t, int(m.group(2)))
            cur_img = {}
            continue
        m = RE_IMG.match(s)
        if m and cur_img is not None:
            y = int(m.group(1))
            cur_img[y] = np.frombuffer(bytes.fromhex(m.group(2)), dtype=np.uint8)
            if len(cur_img) == 96:
                arr = np.zeros((96, 96), np.uint8)
                for k, v in cur_img.items():
                    arr[k, :] = v
                imgs.append((cur_stat[0], cur_stat[1], arr))
                cur_img = None
            continue
        m = RE_LP.search(s)
        if m:
            lp_state = int(m.group(1))
            continue
        m = RE_DEC.search(s)
        if m:
            t = int(m.group(1))
            last_t = t
            dec.append((t, int(m.group(3)), int(m.group(4)), int(m.group(2)),
                        int(m.group(5)), pending_p, lp_state))
            pending_p = None

    with (HERE / "ticks.csv").open("w", newline="", encoding="utf-8-sig") as fh:
        w = csv.writer(fh)
        w.writerow(["device_ms", "motion", "area", "p", "person", "alarm", "lp"])
        for (t, mo, ar, al, pe, p, lp) in dec:
            w.writerow([t, mo, ar, "" if p is None else p, pe, al, lp])

    # contact sheets
    pages = []
    if imgs:
        imgs.sort(key=lambda x: x[0])
        sheets = HERE / "contact_sheet"
        sheets.mkdir(exist_ok=True)
        per = 40
        for start in range(0, len(imgs), per):
            chunk = imgs[start:start + per]
            fig, axes = plt.subplots(5, 8, figsize=(16, 11))
            for ax in axes.ravel():
                ax.axis("off")
            for i, (t, p, arr) in enumerate(chunk):
                ax = axes.ravel()[i]
                ax.imshow(arr, cmap="gray", vmin=0, vmax=255)
                ax.set_title("ms=%d p=%d" % (t, p), fontsize=7)
                ax.axis("off")
            pg = start // per + 1
            f = sheets / ("contact_sheet_p%d.png" % pg)
            fig.suptitle("v22 gate contact sheet p%d (n=%d)" % (pg, len(chunk)), fontsize=12)
            fig.tight_layout(rect=[0, 0, 1, 0.96])
            fig.savefig(f, dpi=110)
            plt.close(fig)
            pages.append(f)

    txt = LOG.read_text(encoding="utf-8", errors="replace")
    gaps = txt.count("### GAP")
    reconn = txt.count("### RECONNECTED")

    L = []
    A = L.append
    A("# v22 入侵→报警关口实测 summary\n")
    A("> 只陈述事实与数字，不作通过/失败判断。\n")
    A("## 固件与位流\n")
    A("| 项 | 值 |")
    A("|---|---|")
    A("| 固件 | `tinyml_pdti8_v19_dump.bin`，477,722 B，CRC32 `9410DBEF`，"
      "SHA256 `8C0AE09D06851257D5412EC834C5BF143D91BFE2F30D111AC298BC571F0D2AD3` |")
    A("| 位流 | `v7_MERGE14.bit`，2,829,903 B，SHA256 `E399F990…41FE8` |")
    A("")
    A("## 开机行\n")
    A("```")
    for b in boot:
        A(b)
    A("```\n")
    A("## 报警区间（设备毫秒）\n")
    if alarms:
        A("| # | 类型 | 设备 ms |")
        A("|---|---|---|")
        for i, (k, ms) in enumerate(alarms, 1):
            A("| %d | %s | %d |" % (i, k, ms))
    else:
        A("**整段无 `MMT_ALARM` 行。**")
    A("")
    A("## 低功耗进入 / 唤醒（设备毫秒）\n")
    if lps:
        A("| # | 事件 | 设备 ms |")
        A("|---|---|---|")
        for i, (k, ms) in enumerate(lps, 1):
            A("| %d | %s | %d |" % (i, k, ms))
    else:
        A("无 MMT_LP_ENTER / MMT_LP_EXIT。")
    A("")
    A("## mean_sensor 每 60 秒中位数\n")
    if pps:
        b = {}
        for t, v in pps:
            b.setdefault(t // 60000, []).append(v)
        A("| 分钟段（设备 ms 起） | 样本 | 中位数 |")
        A("|---|---|---|")
        for k in sorted(b):
            A("| %d | %d | %.0f |" % (k * 60000, len(b[k]), statistics.median(b[k])))
    else:
        A("无 MMT_PP 行。")
    A("")
    A("## 计数\n")
    A("| 项 | 值 |")
    A("|---|---|")
    A("| DEC 帧数 | %d |" % len(dec))
    A("| 96×96 图组 | %d |" % len(imgs))
    A("| GAP 行 | %d |" % gaps)
    A("| 串口重连 | %d |" % reconn)
    A("| 报警开着帧数 | %d |" % sum(1 for x in dec if x[3]))
    A("| person=1 帧数 | %d |" % sum(1 for x in dec if x[4]))
    A("")
    A("## 灯光状态\n")
    A("- 主灯：**待确认**")
    A("- 台灯朝向：**待确认**")
    A("- 衣服颜色：**待确认**")
    (HERE / "summary.md").write_text("\n".join(L) + "\n", encoding="utf-8")
    print("dec=%d imgs=%d pages=%d alarms=%d lps=%d gaps=%d reconn=%d"
          % (len(dec), len(imgs), len(pages), len(alarms), len(lps), gaps, reconn))


if __name__ == "__main__":
    main()
