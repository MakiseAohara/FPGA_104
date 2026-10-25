#!/usr/bin/env python3
"""build_ae.py - build ticks.csv / contact sheets / summary.md for the v20 AE run."""
import csv
import re
import statistics
from pathlib import Path

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np

HERE = Path(__file__).resolve().parent
OUT = HERE.parent / "v20_ae"
LOG = OUT / "log_v20_ae.log"

RE_DEC = re.compile(r"MMT_DEC t=(\d+) f=(\d+).*?alarm_req=(\d+).*?motion=(\d+)"
                    r".*?area=(\d+).*?person=(-?\d+)")
RE_OSD = re.compile(r"MMT_OSD .*?\bp=(-?\d+)")
RE_LP = re.compile(r"MMT_LP f=(\d+) lowpwr=(\d+).*?paused=(\d+)")
RE_PP = re.compile(r"MMT_PP .*?mean_sensor=(\d+)")
RE_IMGSTAT = re.compile(r"MMT_IMGSTAT f=(\d+).*?\bp=(-?\d+)")
RE_IMG = re.compile(r"MMT_IMG (\d\d) ([0-9a-f]{192})")
RE_AE = re.compile(r"MMT_AE (init|\S.*)")
RE_LPENTER = re.compile(r"MMT_LP_ENTER f=(\d+) cnt=(\d+) ms=(\d+)")
RE_LPEXIT = re.compile(r"MMT_LP_EXIT f=(\d+) cnt=(\d+) ms=(\d+)")
RE_ALARM = re.compile(r"MMT_ALARM (start|end) ms=(\d+)")


def parse(log: Path):
    dec, pps, imgs, aes, lps, alarms = [], [], [], [], [], []
    boot = []
    lp_state = 0
    pending_p = None
    last_t = 0
    cur_img = None
    cur_stat = None
    for raw in log.read_text(encoding="utf-8", errors="replace").splitlines():
        s = raw.split("\t", 1)[-1].strip()
        for tag in ("MMT_BOOT", "MMT_LIVE_BOOT", "MMT_CFG", "MMT_CAM", "MMT_DDR_PASS"):
            if s.startswith(tag):
                boot.append(s)
        m = RE_AE.search(s)
        if m:
            aes.append((0 if 'init' in s else last_t, s))
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
            lp_state = int(m.group(2))
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
            alarms.append((m.group(1), int(m.group(2))))
            continue
        m = RE_DEC.search(s)
        if m:
            t = int(m.group(1))
            last_t = t
            dec.append((t, int(m.group(4)), int(m.group(5)), int(m.group(3)),
                        int(m.group(6)), pending_p, lp_state))
            pending_p = None
    return dict(dec=dec, pps=pps, imgs=imgs, aes=aes, lps=lps, alarms=alarms, boot=boot)


def ticks(d, out: Path):
    with out.open("w", newline="", encoding="utf-8-sig") as fh:
        w = csv.writer(fh)
        w.writerow(["device_ms", "motion", "area", "p", "person", "alarm", "lp"])
        for (t, motion, area, alarm, person, p, lp) in d["dec"]:
            w.writerow([t, motion, area, "" if p is None else p, person, alarm, lp])


def sheets(imgs, outdir: Path, per=40):
    if not imgs:
        return []
    outdir.mkdir(exist_ok=True)
    imgs = sorted(imgs, key=lambda x: x[0])
    pages = []
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
        page = start // per + 1
        save = outdir / ("contact_sheet_p%d.png" % page)
        fig.suptitle("v20 AE contact sheet page %d (n=%d, sorted by device ms)"
                     % (page, len(chunk)), fontsize=12)
        fig.tight_layout(rect=[0, 0, 1, 0.96])
        fig.savefig(save, dpi=110)
        plt.close(fig)
        pages.append(save)
    return pages


def main():
    d = parse(LOG)
    ticks(d, OUT / "ticks.csv")
    pages = sheets(d["imgs"], OUT / "contact_sheet")
    print("dec=%d pp=%d imgs=%d pages=%d ae=%d lps=%d alarms=%d"
          % (len(d["dec"]), len(d["pps"]), len(d["imgs"]), len(pages),
             len(d["aes"]), len(d["lps"]), len(d["alarms"])))

    L = []
    A = L.append
    A("# v20（v19 + 自动曝光冻结）30 分钟连续抓取 summary\n")
    A("> 只列事实与数字，不作通过/未通过判断。\n")

    pre = 0
    for raw in LOG.read_text(encoding='utf-8', errors='replace').splitlines():
        if 'MMT_BOOT' in raw:
            break
        if '\\t' in raw:
            pre += 1
    A("## 抓取起点说明\n")
    A("本日志按任务要求**先开抓、后复位**，因此开头 %d 行是**上一版固件（v19）的尾部输出**，" % pre)
    A("其 device_ms 属于 v19 的时间轴；MMT_BOOT 之后才是 v20 的完整启动与 30 分钟数据。\n")
    A("## 启动行\n")
    A("```")
    for b in d["boot"]:
        A(b)
    A("```\n")

    A("## MMT_AE 行（曝光 / 增益调整）\n")
    if d["aes"]:
        A("| # | 设备 ms | 内容 |")
        A("|---|---|---|")
        for i, (t, s) in enumerate(d["aes"], 1):
            A("| %d | %d | `%s` |" % (i, t, s.replace("|", "\\|")))
    else:
        A("无 MMT_AE 行。")
    A("")

    A("## mean_sensor 每 60 秒中位数\n")
    if d["pps"]:
        buckets = {}
        for t, v in d["pps"]:
            buckets.setdefault(t // 60000, []).append(v)
        A("| 分钟段（设备 ms 起） | 样本数 | 中位数 | 最小 | 最大 |")
        A("|---|---|---|---|---|")
        for k in sorted(buckets):
            v = buckets[k]
            A("| %d | %d | %.0f | %d | %d |"
              % (k * 60000, len(v), statistics.median(v), min(v), max(v)))
    else:
        A("无 MMT_PP 行。")
    A("")

    A("## 报警区间（设备毫秒）\n")
    if d["alarms"]:
        A("| # | 类型 | 设备 ms |")
        A("|---|---|---|")
        for i, (k, ms) in enumerate(d["alarms"], 1):
            A("| %d | %s | %d |" % (i, k, ms))
        A("")
        A("合计 start=%d，end=%d。"
          % (sum(1 for x in d["alarms"] if x[0] == "start"),
             sum(1 for x in d["alarms"] if x[0] == "end")))
    else:
        A("**无 MMT_ALARM 行（整段未触发报警）。**")
    A("")

    A("## 低功耗进入 / 唤醒（设备毫秒）\n")
    if d["lps"]:
        A("| # | 事件 | 设备 ms |")
        A("|---|---|---|")
        for i, (k, ms) in enumerate(d["lps"], 1):
            A("| %d | %s | %d |" % (i, k, ms))
    else:
        A("无 MMT_LP_ENTER / MMT_LP_EXIT。")
    A("")

    n_bad = sum(1 for (t, mo, ar, al, pe, p, lp) in d["dec"]
                if p is not None and p < -40 and al)
    A("## 关键计数\n")
    A("| 项 | 值 |")
    A("|---|---|")
    A("| DEC 帧数 | %d |" % len(d["dec"]))
    A("| 96×96 图组 | %d |" % len(d["imgs"]))
    A("| 「p < −40 且报警开着」帧数 | %d |" % n_bad)
    A("| 报警开着帧数 | %d |" % sum(1 for x in d["dec"] if x[3]))
    A("| person=1 帧数 | %d |" % sum(1 for x in d["dec"] if x[4]))
    A("| 低功耗帧数 | %d |" % sum(1 for x in d["dec"] if x[6]))
    A("")

    txt = LOG.read_text(encoding="utf-8", errors="replace")
    gaps = txt.count("### GAP")
    reconn = txt.count("### RECONNECTED")
    A("## 日志完整性\n")
    A("| 项 | 值 |")
    A("|---|---|")
    A("| GAP 行数 | %d |" % gaps)
    A("| 串口重连次数 | %d |" % reconn)
    A("| 首行 | `%s` |" % txt.splitlines()[0][:80])
    A("| 末行 | `%s` |" % txt.splitlines()[-1][:80])
    A("")

    A("## 环境\n")
    A("- 台灯朝向：**待操作者确认**")
    A("- 房间灯状态：**待操作者确认**")
    A("- 摄像头对准：寝室门（未移动）")
    (OUT / "summary.md").write_text("\n".join(L) + "\n", encoding="utf-8")
    print("wrote summary.md, gaps=%d reconn=%d" % (gaps, reconn))


if __name__ == "__main__":
    main()
