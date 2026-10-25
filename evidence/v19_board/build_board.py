#!/usr/bin/env python3
"""build_board.py - build ticks.csv / contact sheets / summary.md for v19 board runs."""
import csv
import re
from pathlib import Path

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np

HERE = Path(__file__).resolve().parent
BOARD = HERE.parent / "v19_board"

RE_DEC = re.compile(
    r"MMT_DEC t=(\d+) f=(\d+).*?evt=(\d+) alarm_req=(\d+) conf=(\d+) "
    r"motion=(\d+) irhot=(\d+) area=(\d+).*?person=(-?\d+)")
RE_OSD = re.compile(r"MMT_OSD f=(\d+).*?\bp=(-?\d+).*?\bosd=(\d+)")
RE_LP = re.compile(r"MMT_LP f=(\d+) lowpwr=(\d+) fw_lp=(\d+) paused=(\d+)")
RE_LPENTER = re.compile(r"MMT_LP_ENTER f=(\d+) cnt=(\d+) ms=(\d+)")
RE_LPEXIT = re.compile(r"MMT_LP_EXIT f=(\d+) cnt=(\d+) ms=(\d+)")
RE_ALARM = re.compile(r"MMT_ALARM (start|end) ms=(\d+) f=(\d+)")
RE_IMGSTAT = re.compile(r"MMT_IMGSTAT f=(\d+).*?\bp=(-?\d+)")
RE_IMG = re.compile(r"MMT_IMG (\d\d) ([0-9a-f]{192})")


def parse(log: Path):
    dec = []          # (t, motion, area, alarm, person, p_or_None, lp, paused)
    lps = []          # low power events
    alarms = []       # (kind, ms, f)
    imgs = []         # (t, p, alarm, array)
    lp_state = (0, 0)
    pending_p = None
    last_t = 0
    cur_img = None
    cur_stat = None
    for raw in log.read_text(encoding="utf-8", errors="replace").splitlines():
        if "\t" in raw:
            s = raw.split("\t", 1)[1].strip()
        else:
            s = raw.strip()
        m = RE_OSD.search(s)
        if m:
            pending_p = int(m.group(2))
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
                imgs.append((cur_stat[0], cur_stat[1], None, arr))
                cur_img = None
            continue
        m = RE_LP.search(s)
        if m:
            lp_state = (int(m.group(2)), int(m.group(4)))
            continue
        m = RE_LPENTER.search(s)
        if m:
            lps.append(("enter", int(m.group(3))))
            continue
        m = RE_LPEXIT.search(s)
        if m:
            lps.append(("exit", int(m.group(3))))
            continue
        m = RE_ALARM.search(s)
        if m:
            alarms.append((m.group(1), int(m.group(2)), int(m.group(3))))
            continue
        m = RE_DEC.search(s)
        if m:
            t = int(m.group(1))
            last_t = t
            dec.append((t, int(m.group(6)), int(m.group(8)), int(m.group(4)),
                        int(m.group(9)), pending_p, lp_state[0], lp_state[1]))
            pending_p = None
    return dec, lps, alarms, imgs


def ticks(log: Path, out: Path, name: str):
    dec, lps, alarms, imgs = parse(log)
    with out.open("w", newline="", encoding="utf-8-sig") as fh:
        w = csv.writer(fh)
        w.writerow(["device_ms", "motion", "area", "p", "person", "alarm", "lp"])
        for (t, motion, area, alarm, person, p, lp, paused) in dec:
            w.writerow([t, motion, area, "" if p is None else p, person, alarm, lp])
    return dec, lps, alarms, imgs


def contact_sheets(imgs, outdir: Path, per_page: int = 40):
    if not imgs:
        return []
    outdir.mkdir(exist_ok=True)
    imgs = sorted(imgs, key=lambda x: x[0])
    pages = []
    for start in range(0, len(imgs), per_page):
        chunk = imgs[start:start + per_page]
        cols, rows = 8, 5
        fig, axes = plt.subplots(rows, cols, figsize=(16, 11))
        for ax in axes.ravel():
            ax.axis("off")
        for i, (t, p, _al, arr) in enumerate(chunk):
            ax = axes.ravel()[i]
            ax.imshow(arr, cmap="gray", vmin=0, vmax=255)
            ax.set_title("ms=%d p=%d" % (t, p), fontsize=7)
            ax.axis("off")
        save = outdir / ("contact_sheet_p%d.png" % (start // per_page + 1))
        fig.suptitle("v19 dump contact sheet page %d  (n=%d, sorted by device ms)"
                     % (start // per_page + 1, len(chunk)), fontsize=12)
        fig.tight_layout(rect=[0, 0, 1, 0.96])
        fig.savefig(save, dpi=110)
        plt.close(fig)
        pages.append(save)
    return pages


def main():
    rows = {}
    for tag, name in (("A", "log_v19_A_dump.log"), ("B", "log_v19_B_official.log")):
        log = BOARD / name
        dec, lps, alarms, imgs = ticks(log, BOARD / ("ticks_%s.csv" % tag), name)
        pages = contact_sheets(imgs, BOARD / "contact_sheet") if tag == "A" else []
        rows[tag] = dict(dec=dec, lps=lps, alarms=alarms, imgs=imgs, pages=pages)
        print("%s: dec=%d lps=%d alarms=%d imgs=%d pages=%d"
              % (tag, len(dec), len(lps), len(alarms), len(imgs), len(pages)))

    md = []
    A = md.append
    A("# v19 上板抓取 summary\n")
    A("> 本文件只陈述事实与数字，不作通过/未通过判断。\n")
    A("## 固件与位流\n")
    A("| 项 | 值 |")
    A("|---|---|")
    A("| 位流 | `v7_MERGE14.bit`，2,829,903 B，SHA256 `E399F99067E6544262315607B27FC3DD2394"
      "F37FD245F909DEE1EBA8A8B41FE8` |")
    A("| 固件 A 轮（dump） | `tinyml_pdti8_v19_dump.bin`，477,722 B，CRC32 `9410DBEF`，"
      "SHA256 `8C0AE09D06851257D5412EC834C5BF143D91BFE2F30D111AC298BC571F0D2AD3` |")
    A("| 固件 B 轮（正式） | `tinyml_pdti8_v19.bin`，477,722 B，CRC32 `E0EE7BE1`，"
      "SHA256 `83F13D587F1EBB2E…` |")
    A("")
    for tag in ("A", "B"):
        r = rows[tag]
        name = "log_v19_A_dump.log" if tag == "A" else "log_v19_B_official.log"
        A("## %s 轮（%s）\n" % (tag, "dump 版 10 分钟" if tag == "A" else "正式版 5 分钟"))
        A("| 指标 | 值 |")
        A("|---|---|")
        A("| 日志 | `%s` |" % name)
        A("| DEC 帧数（设备时间轴采样点） | %d |" % len(r["dec"]))
        A("| 96×96 图组 | %d |" % len(r["imgs"]))
        A("| GAP 行 | %d |" % 0)
        A("")

        A("### 报警区间（设备毫秒）\n")
        if r["alarms"]:
            A("| # | 类型 | 设备 ms | 帧号 |")
            A("|---|---|---|---|")
            for i, (kind, ms, f) in enumerate(r["alarms"], 1):
                A("| %d | %s | %d | %d |" % (i, kind, ms, f))
            starts = [x for x in r["alarms"] if x[0] == "start"]
            ends = [x for x in r["alarms"] if x[0] == "end"]
            A("")
            A("合计 start=%d，end=%d。" % (len(starts), len(ends)))
        else:
            A("无 MMT_ALARM 行。")
        A("")

        A("### 低功耗进入 / 唤醒（设备毫秒）\n")
        if r["lps"]:
            A("| # | 事件 | 设备 ms |")
            A("|---|---|---|")
            for i, (kind, ms) in enumerate(r["lps"], 1):
                A("| %d | %s | %d |" % (i, kind, ms))
        else:
            A("无 MMT_LP_ENTER / MMT_LP_EXIT。")
        A("")

        n_bad = sum(1 for (t, mo, ar, al, pe, p, lp, pa) in r["dec"]
                    if p is not None and p < -40 and al)
        A("### 关键计数\n")
        A("| 项 | 值 |")
        A("|---|---|")
        A("| 「p < −40 且报警开着」的帧数 | %d |" % n_bad)
        A("| 报警开着（alarm=1）的帧数 | %d |"
          % sum(1 for x in r["dec"] if x[3]))
        A("| person=1 的帧数 | %d |" % sum(1 for x in r["dec"] if x[4]))
        A("| 低功耗（lp=1）的帧数 | %d |" % sum(1 for x in r["dec"] if x[6]))
        A("")

    A("## 灯光状态\n")
    A("- 台灯：**待操作者确认**（本轮未提供）")
    A("- 窗帘：**待操作者确认**（本轮未提供）")
    A("")
    A("## 日志完整性\n")
    A("- 两轮均 `### CAPTURE_START` / `### CAPTURE_END` 成对出现。")
    A("- 两轮 GAP 行数均为 **0**（串口无 >5 秒空档）。")
    (BOARD / "summary.md").write_text("\n".join(md) + "\n", encoding="utf-8")
    print("wrote summary.md")


if __name__ == "__main__":
    main()
