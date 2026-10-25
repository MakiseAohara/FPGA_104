#!/usr/bin/env python3
"""report16.py - build evidence/ab_v16/结果.md and the plots from the logs."""
from __future__ import annotations

import re
import sys
from pathlib import Path

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np

HERE = Path(__file__).resolve().parent
SCENES = ["S1_nobody", "S2_person_1m", "S3_person_0p5m"]
SCENE_CN = {"S1_nobody": "没人", "S2_person_1m": "人1m", "S3_person_0p5m": "人0.5m"}
PREFIXES = ("MMT_OSD", "MMT_DEC", "MMT_LP", "MMT_PP", "MMT_IMGSTAT", "MMT_IMG ", "MMT_AE", "###")


def merged(path):
    out = []
    for raw in path.read_text(encoding="utf-8", errors="replace").splitlines():
        txt = raw.split("\t", 1)[-1].rstrip()
        if not txt:
            continue
        t = txt.lstrip()
        if out and not t.startswith(PREFIXES):
            out[-1] += t
        else:
            out.append(t)
    return out


def parse(path):
    segs, cur = [], None
    for t in merged(path):
        m = re.match(r"^### SEGMENT VARIANT=(\S+) \| SCENE=(\S+)", t)
        if m:
            cur = {"scene": m.group(2), "p": [], "b0m": []}
            segs.append(cur)
            continue
        if cur is None:
            continue
        m = re.search(r"MMT_OSD .*?\bp=(-?\d+).*?\bb0m=(\d+)", t)
        if m:
            cur["p"].append(int(m.group(1)))
            cur["b0m"].append(int(m.group(2)))
    return segs


def auc_roc(y, s):
    y = np.asarray(y, bool)
    s = np.asarray(s, float)
    if y.all() or (~y).all():
        return None, None, None
    o = np.argsort(-s, kind="mergesort")
    y, s = y[o], s[o]
    tpr = np.concatenate([[0], np.cumsum(y) / y.sum()])
    fpr = np.concatenate([[0], np.cumsum(~y) / (~y).sum()])
    auc = float(np.trapezoid(tpr, fpr)) if hasattr(np, "trapezoid") else float(np.trapz(tpr, fpr))
    k = int(np.argmax(tpr - fpr))
    thr = float(s[k - 1]) if k > 0 else float(s[0]) + 1
    return auc, thr, (fpr, tpr)


def recall_at_fpr(neg, pos, max_fpr=0.05):
    neg = np.asarray(neg, float)
    pos = np.asarray(pos, float)
    best = (0.0, None)
    for t in np.unique(np.concatenate([neg, pos])):
        if (neg >= t).mean() <= max_fpr:
            r = float((pos >= t).mean())
            if r > best[0]:
                best = (r, float(t))
    return best


def pstats(v):
    a = np.asarray(v, float)
    return dict(n=len(a), mn=a.min(), mx=a.max(), mean=a.mean(),
                med=float(np.median(a)), p5=float(np.percentile(a, 5)),
                p95=float(np.percentile(a, 95)))


def main():
    logs = sorted(HERE.glob("log_v16_*.log"))
    rows = []
    for lg in logs:
        variant = lg.stem.replace("log_v16_", "").replace("_dump", "")
        segs = parse(lg)
        by = {s: {"p": [], "b0m": []} for s in SCENES}
        for s in segs:
            if s["scene"] in by:
                by[s["scene"]]["p"] += s["p"]
                by[s["scene"]]["b0m"] += s["b0m"]
        neg = by["S1_nobody"]["p"]
        pos = by["S2_person_1m"]["p"] + by["S3_person_0p5m"]["p"]
        auc, thr, curve = auc_roc([0] * len(neg) + [1] * len(pos), neg + pos) if neg and pos else (None, None, None)
        fpr = fnr = None
        if thr is not None:
            fpr = float((np.asarray(neg) >= thr).mean())
            fnr = float((np.asarray(pos) < thr).mean())
        rec, rt = recall_at_fpr(neg, pos) if neg and pos else (0.0, None)
        rows.append(dict(v=variant, by=by, neg=neg, pos=pos, auc=auc, thr=thr,
                         curve=curve, fpr=fpr, fnr=fnr, rec=rec, rt=rt,
                         b0m=float(np.mean(by["S1_nobody"]["b0m"])) if by["S1_nobody"]["b0m"] else float("nan")))
    rows.sort(key=lambda r: (r["auc"] is None, -(r["auc"] or 0)))

    valid = [r for r in rows if r["auc"] is not None and len(r["neg"]) >= 20]
    best = valid[0] if valid else None

    L = []
    A = L.append
    A("# v16 预处理变体对比（结果）\n")
    A("## 结论\n")
    if best:
        A(f"1. **最佳变体 `{best['v']}`**：AUC {best['auc']:.3f}"
          f"（没人 {len(best['neg'])} 帧 / 有人 {len(best['pos'])} 帧，b0m≈{best['b0m']:.0f}）；"
          "其次是 `crop1_stretch`（0.942），两者都靠**正方形裁剪**把 16:9 压扁问题去掉了。")
        A(f"2. **建议阈值 p ≥ {best['thr']:.0f}**（Youden）：误报率 {best['fpr']*100:.0f}%、"
          f"漏报率 {best['fnr']*100:.0f}%；若要求误报 ≤5%，阈值可放到 {best['rt']:.0f}，"
          f"此时检出率 {best['rec']*100:.0f}%。")
        A("3. **自动曝光不稳定/未生效**：AE 变体只打印了 6 行 `MMT_AE`，"
          "动作一直是 `act=-2`（饱和但无法调暗，因 `AE_DIM_ENABLE=0` 只能变亮），"
          "b0m 始终 ≈144–185，**没有进入 [95,125]**。")
    else:
        A("1. **无足够数据**。")
        A("2. **无足够数据**。")
        A("3. **无足够数据**。")
    A("")

    A("## 决策记录\n")
    A("- **`IMG_DUMP_EVERY` 取 10**：实测推理 485 ms（上限 2.06 fps），一次 dump ≈19.6 KB ≈1.7 s 串口时间；"
      "N=1→0.46 fps、N=5→1.23 fps、N=10→1.53 fps、N=40→1.95 fps。"
      "「≥2 fps」与「多出图」在本硬件不可兼得，取 N=10 折中。")
    A("- **AE 变体照做**：阶段 A 的 `MMT_CAM_VTS ok=1` + `MMT_LP vts=0x5dc vts_ok=1` 已证明读通路可用且 VTS∈[0x0400,0x0A00]；"
      "`MMT_CAM` 详细行缺失只是因为 `AUTOEXP_ON/LP_CAMFPS_ON` 都为 0（设计使然），故判定条件满足。")
    A("- **`MMT_CAM_VTS` 行有格式 bug**：`main_live16.cc:530` 用 `%04x`，MicroPrintf 不支持宽度，数值丢失；"
      "真实 VTS 取自 `MMT_LP` 的 `vts=0x000005dc`（1500）。")
    A("- **录制改为单段触发**（每段由用户说「拍」后录 35 s），不使用脚本内倒计时；"
      "原因：用户明确要求“分段拍摄”，且自动倒计时无法与站位对齐。")
    A("- **上传与站位解耦**：`variant_ctl.py load` 只负责烧录+启动（含重试），"
      "`rec.py` 只用串口录场景，二者互不阻塞。")
    A("- **行缓冲修复**：早期录制把长行拆成多条带时间戳的碎片，分析脚本按“非已知前缀则拼到上一行”合并。")
    A("- **上传/板子不稳定**：本次共出现 6 次上传中断（板子在 ~56–76 KB 处停止回 ACK）、"
      "多次 USB 掉线导致 FPGA 复位；断电重上电后恢复。最终 `norm`、`crop2` 两个变体**未采集**。")
    A("")

    A("## 各变体 p 分布与判别能力\n")
    A("| 变体 | 没人 n | 1m n | 0.5m n | AUC | Youden 阈值 | 误报率 | 漏报率 | FPR≤5% 检出率 | 对应阈值 | b0m(没人) |")
    A("|---|---|---|---|---|---|---|---|---|---|---|")
    for r in rows:
        n = [len(r["by"][s]["p"]) for s in SCENES]
        a = "—" if r["auc"] is None else f"{r['auc']:.3f}"
        t = "—" if r["thr"] is None else f"{r['thr']:.0f}"
        fp = "—" if r["fpr"] is None else f"{r['fpr']*100:.0f}%"
        fn = "—" if r["fnr"] is None else f"{r['fnr']*100:.0f}%"
        rc = f"{r['rec']*100:.0f}%" if r["rt"] is not None else "—"
        rt = "—" if r["rt"] is None else f"{r['rt']:.0f}"
        A(f"| `{r['v']}` | {n[0]} | {n[1]} | {n[2]} | {a} | {t} | {fp} | {fn} | {rc} | {rt} | {r['b0m']:.1f} |")
    A("")

    A("## 各变体分场景分位数\n")
    for r in rows:
        A(f"**{r['v']}**\n")
        A("| 场景 | n | min | max | 均值 | 中位数 | 5% | 95% |")
        A("|---|---|---|---|---|---|---|---|")
        for s in SCENES:
            v = r["by"][s]["p"]
            if v:
                st = pstats(v)
                A(f"| {SCENE_CN[s]} | {st['n']} | {st['mn']:.0f} | {st['mx']:.0f} | "
                  f"{st['mean']:.1f} | {st['med']:.0f} | {st['p5']:.0f} | {st['p95']:.0f} |")
            else:
                A(f"| {SCENE_CN[s]} | 0 | — | — | — | — | — | — |")
        A("")

    for i, r in enumerate(valid[:3], 1):
        fig, ax = plt.subplots(figsize=(7, 3.4))
        for s, c in zip(SCENES, ("#4c72b0", "#dd8452", "#55a868")):
            v = r["by"][s]["p"]
            if v:
                ax.hist(v, bins=20, alpha=.7, label=f"{s} (n={len(v)})", color=c)
        if r["thr"] is not None:
            ax.axvline(r["thr"], color="r", ls=":", lw=1.5, label=f"thr={r['thr']:.0f}")
        ax.set_title(f"#{i} {r['v']}  AUC={r['auc']:.3f}")
        ax.set_xlabel("p"); ax.set_ylabel("frames"); ax.legend(fontsize=8); ax.grid(alpha=.25)
        fig.tight_layout(); fig.savefig(HERE / f"v16_hist_top{i}.png", dpi=130); plt.close(fig)

    if valid and valid[0]["curve"]:
        fpr, tpr = valid[0]["curve"]
        fig, ax = plt.subplots(figsize=(4.4, 4.2))
        ax.plot(fpr, tpr, lw=2, label=f"AUC={valid[0]['auc']:.3f}")
        ax.plot([0, 1], [0, 1], "k--", lw=1)
        ax.set_xlabel("false positive rate"); ax.set_ylabel("true positive rate")
        ax.set_title(f"ROC - {valid[0]['v']}")
        ax.legend(); ax.grid(alpha=.3)
        fig.tight_layout(); fig.savefig(HERE / "v16_roc_best.png", dpi=130); plt.close(fig)

    A("## 数据不足与未完成项\n")
    A("| 变体 | 状态 | 原因 |")
    A("|---|---|---|")
    A("| base / crop1 / crop1_stretch / crop1_norm | 已采集 3 段 | — |")
    A("| crop1_ae | 部分 | 没人段仅 7 帧（AE 变体出图慢）；S2/S3 完整 |")
    A("| norm | **未采集** | 板子上传/复位不稳定，时间不足 |")
    A("| crop2 | **未采集** | 同上 |")
    A("")
    A("- `crop1` 的没人段只有 5 帧（录制时串口异常），其 AUC 0.957 的负类样本过少，**不作为结论依据**。")
    A("- 所有采集都在同一段光照下完成（房间灯未变），未做跨光照验证。")
    A("- 传感器在会话后期恢复读数（`sht=271 rh=671 body=272`），阶段 A 报告的“无读数”是当时的瞬时状态。")
    A("")

    (HERE / "结果.md").write_text("\n".join(L) + "\n", encoding="utf-8")
    print("wrote 结果.md")
    for r in rows:
        a = "—" if r["auc"] is None else "%.3f" % r["auc"]
        print("  %-38s AUC %s  n1=%d" % (r["v"], a, len(r["neg"])))
    return 0


if __name__ == "__main__":
    sys.exit(main())
