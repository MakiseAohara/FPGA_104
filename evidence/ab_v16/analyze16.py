#!/usr/bin/env python3
"""analyze16.py - parse v16 capture logs (with fragment merging) and report.

The early recordings split long serial lines across several timestamped entries.
Any entry whose text does not begin with a known prefix is appended to the
previous line, which restores the original lines.
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parent
PREFIXES = ("MMT_OSD", "MMT_DEC", "MMT_LP", "MMT_PP", "MMT_IMGSTAT", "MMT_IMG ", "###")
SCENES = ["S1_nobody", "S2_person_1m", "S3_person_0p5m"]


def raw_lines(path: Path):
    for raw in path.read_text(encoding="utf-8", errors="replace").splitlines():
        if "\t" in raw:
            _, txt = raw.split("\t", 1)
        else:
            txt = raw
        yield txt.rstrip()


def merged(path: Path):
    out = []
    for txt in raw_lines(path):
        if not txt:
            continue
        t = txt.lstrip()
        if out and not t.startswith(PREFIXES):
            out[-1] += t
        else:
            out.append(t)
    return out


def parse(path: Path):
    segs = []
    cur = None
    for t in merged(path):
        m = re.match(r"^### SEGMENT VARIANT=(\S+) \| SCENE=(\S+)", t)
        if m:
            cur = {"variant": m.group(1), "scene": m.group(2), "p": [], "b0m": []}
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
            rec = float((pos >= t).mean())
            if rec > best[0]:
                best = (rec, float(t))
    return best


def main():
    logs = sorted(HERE.glob("log_v16_*.log"))
    if not logs:
        print("no logs")
        return 1
    rows = []
    for lg in logs:
        variant = lg.stem.replace("log_v16_", "")
        segs = parse(lg)
        by = {}
        for s in segs:
            by.setdefault(s["scene"], {"p": [], "b0m": []})
            by[s["scene"]]["p"] += s["p"]
            by[s["scene"]]["b0m"] += s["b0m"]
        neg = by.get("S1_nobody", {"p": []})["p"]
        pos = by.get("S2_person_1m", {"p": []})["p"] + by.get("S3_person_0p5m", {"p": []})["p"]
        auc, thr, curve = auc_roc([0] * len(neg) + [1] * len(pos), neg + pos) if neg and pos else (None, None, None)
        fpr = fnr = None
        if thr is not None:
            fpr = float((np.asarray(neg) >= thr).mean())
            fnr = float((np.asarray(pos) < thr).mean())
        rec, rt = recall_at_fpr(neg, pos) if neg and pos else (0.0, None)
        b0 = by.get("S1_nobody", {}).get("b0m", [])
        rows.append(dict(v=variant, neg=neg, pos=pos, auc=auc, thr=thr, curve=curve,
                         fpr=fpr, fnr=fnr, rec=rec, rt=rt,
                         b0m=float(np.mean(b0)) if b0 else float("nan"),
                         n1=len(by.get("S1_nobody", {"p": []})["p"]),
                         n2=len(by.get("S2_person_1m", {"p": []})["p"]),
                         n3=len(by.get("S3_person_0p5m", {"p": []})["p"])))
    rows.sort(key=lambda r: (r["auc"] is None, -(r["auc"] or 0)))
    print("%-32s %5s %5s %5s %6s %6s %6s %6s %7s" %
          ("variant", "n1", "n2", "n3", "AUC", "thr", "FPR", "FNR", "b0m"))
    for r in rows:
        a = "—" if r["auc"] is None else "%.3f" % r["auc"]
        t = "—" if r["thr"] is None else "%.0f" % r["thr"]
        fp = "—" if r["fpr"] is None else "%.0f%%" % (r["fpr"] * 100)
        fn = "—" if r["fnr"] is None else "%.0f%%" % (r["fnr"] * 100)
        print("%-32s %5d %5d %5d %6s %6s %6s %6s %7.1f" %
              (r["v"], r["n1"], r["n2"], r["n3"], a, t, fp, fn, r["b0m"]))
    return 0


if __name__ == "__main__":
    sys.exit(main())
