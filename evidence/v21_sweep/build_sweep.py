#!/usr/bin/env python3
"""build_sweep.py - sweep_table.csv + two-pass comparison + summary.md for v21."""
import csv
import re
import statistics
from pathlib import Path

HERE = Path(__file__).resolve().parent
LOG = HERE / "log_v21_sweep.log"

# bsp_printf has no width modifiers, so the line looks like:
#   MMT_SWEEP pass=0 idx=1 vts=000005dcp20=0x00000640 gc=0x00000080 gf=0x0000002a
RE_SWEEP = re.compile(
    r"MMT_SWEEP pass=(\d+) idx=(\d+) vts=([0-9a-f]+)p20=0x([0-9a-f]+) "
    r"gc=0x([0-9a-f]+) gf=0x([0-9a-f]+)")
RE_PP = re.compile(r"MMT_PP .*?mean_sensor=(\d+).*?\bhi=(\d+)")
RE_LP = re.compile(r"MMT_LP .*?camfps=(\d+)")
RE_DEC = re.compile(r"MMT_DEC t=(\d+)")
RE_SWEEP_ERR = re.compile(r"MMT_SWEEP_ERR")


def main():
    lines = LOG.read_text(encoding="utf-8", errors="replace").splitlines()

    # split the log into sweep-state windows
    windows = []          # [ {meta, pp:[], hi:[], camfps:[]} ]
    cur = None
    last_t = 0
    for raw in lines:
        s = raw.split("\t", 1)[-1].strip()
        m = RE_SWEEP.search(s)
        if m:
            cur = dict(pass_=int(m.group(1)), idx=int(m.group(2)),
                       vts=int(m.group(3), 16), exp20=int(m.group(4), 16),
                       gc=int(m.group(5), 16), gf=int(m.group(6), 16),
                       pp=[], hi=[], cf=[])
            windows.append(cur)
            continue
        if cur is None:
            continue
        if s.startswith("MMT_SWEEP_DONE"):
            cur = None          # 扫描结束后的数据不计入最后一段
            continue
        m = RE_PP.search(s)
        if m:
            cur["pp"].append(int(m.group(1)))
            cur["hi"].append(int(m.group(2)))
            continue
        m = RE_LP.search(s)
        if m:
            cur["cf"].append(int(m.group(1)))

    rows = []
    for w in windows:
        pp = w["pp"][4:]          # 去掉前 4 个样本
        if pp:
            rows.append(dict(w, n_raw=len(w["pp"]), n=len(pp),
                             med=statistics.median(pp), mn=min(pp), mx=max(pp),
                             hi_med=statistics.median(w["hi"][4:]) if len(w["hi"]) > 4 else None,
                             cf_med=statistics.median(w["cf"]) if w["cf"] else None))
        else:
            rows.append(dict(w, n_raw=len(w["pp"]), n=0, med=None, mn=None, mx=None,
                             hi_med=None, cf_med=None))

    with (HERE / "sweep_table.csv").open("w", newline="", encoding="utf-8-sig") as fh:
        w = csv.writer(fh)
        w.writerow(["pass", "idx", "vts", "exp20", "gc", "gf", "n_samples_raw",
                    "n_after_drop4", "mean_sensor_med", "mean_sensor_min",
                    "mean_sensor_max", "hi_med", "camfps_med"])
        for r in rows:
            w.writerow([r["pass_"], r["idx"], r["vts"], "0x%05X" % r["exp20"],
                        "0x%02X" % r["gc"], "0x%02X" % r["gf"], r["n_raw"], r["n"],
                        "" if r["med"] is None else r["med"],
                        "" if r["mn"] is None else r["mn"],
                        "" if r["mx"] is None else r["mx"],
                        "" if r["hi_med"] is None else r["hi_med"],
                        "" if r["cf_med"] is None else r["cf_med"]])

    # two-pass comparison
    by = {}
    for r in rows:
        by.setdefault(r["idx"], {})[r["pass_"]] = r["med"]
    with (HERE / "two_pass_diff.csv").open("w", newline="", encoding="utf-8-sig") as fh:
        w = csv.writer(fh)
        w.writerow(["idx", "exp20", "gc", "gf", "pass0_med", "pass1_med", "diff"])
        for idx in sorted(by):
            p0 = by[idx].get(0)
            p1 = by[idx].get(1)
            meta = next(r for r in rows if r["idx"] == idx)
            d = "" if (p0 is None or p1 is None) else p1 - p0
            w.writerow([idx, "0x%05X" % meta["exp20"], "0x%02X" % meta["gc"],
                        "0x%02X" % meta["gf"],
                        "" if p0 is None else p0, "" if p1 is None else p1, d])

    # summary
    boot = [l.split("\t", 1)[-1].strip() for l in lines
            if any(k in l for k in ("MMT_LIVE_BOOT", "MMT_CFG", "MMT_CAM ", "MMT_BOOT"))]
    err = sum(1 for l in lines if RE_SWEEP_ERR.search(l))
    gaps = sum(1 for l in lines if "### GAP" in l)
    reconn = sum(1 for l in lines if "### RECONNECTED" in l)
    done = sum(1 for l in lines if "MMT_SWEEP_DONE" in l)

    L = []
    A = L.append
    A("# v21 曝光标定扫描 summary\n")
    A("> 只陈述事实与数字，不作通过/失败判断。\n")
    A("## 启动行\n")
    A("```")
    for b in boot:
        A(b)
    A("```\n")
    A("## 计数\n")
    A("| 项 | 值 |")
    A("|---|---|")
    A("| MMT_SWEEP 状态切换行 | %d |" % len(windows))
    A("| MMT_SWEEP_ERR | **%d** |" % err)
    A("| MMT_SWEEP_DONE | %d |" % done)
    A("| GAP 行 | %d |" % gaps)
    A("| 串口重连 | %d |" % reconn)
    A("")
    A("## 说明\n")
    A("- 固件：`-DAUTOEXP_ON=0 -DLOWPOWER_ON=0 -DIMG_DUMP_EVERY=40 -DSWEEP_ON=1`，"
      "决策函数与 v19/v20 逐字相同（见 v21 报告）。")
    A("- 扫描每状态停留 12 个循环帧；`mean_sensor` 统计**去掉前 4 个样本**后的中位数/最小/最大。")
    A("- `bsp_printf` 不支持 `%lu`/`%02x` 宽度，`MMT_SWEEP` 行实际打印为 "
      "`vts=000005dcp20=0x0001bbf0`（`exp20=` 被吞掉 `ex`），数据仍可解析。")
    A("- `hi` 取自 `MMT_PP` 的 `hi=`；`camfps` 取自 `MMT_LP`。")
    A("- 镜头对着寝室门，灯光未改动；期间有人经过未干预，故用中位数处理。")
    (HERE / "summary.md").write_text("\n".join(L) + "\n", encoding="utf-8")

    print("windows=%d err=%d done=%d gaps=%d reconn=%d" % (len(windows), err, done, gaps, reconn))
    for r in rows[:4]:
        print("  pass=%d idx=%2d exp20=0x%05X n=%2d med=%s" %
              (r["pass_"], r["idx"], r["exp20"], r["n"], r["med"]))


if __name__ == "__main__":
    main()
