#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""mot_replay.py - 离线回放：把日志里逐帧的检测框灌进跟踪器关联/生命周期逻辑，
对比"基线 / v17 阻尼预测 / v17+v16(GATE+KEEP)"三种配置的 ID 稳定性。

说明：检测框取自 MMT_TRK（板端输出），因此这是"关联层"的 A/B，
不包含差分/连通域部分（那部分由板上 RTL/固件决定，回放不改变它）。
用法: py -3 tools/mot_replay.py out\ev1\serial.log out\ev2\serial.log out\ev3\serial.log [--md file]
"""
import re, sys, json
from pathlib import Path

TRK = re.compile(r"MMT_TRK f=(\d+) id=(\d+) c=(-?\d+),(-?\d+) b=(-?\d+),(-?\d+),(-?\d+),(-?\d+)")
DEC = re.compile(r"MMT_DEC t=\d+ f=(\d+).*?person=(\d)")

MAX_TRK, IOU_THR, GATE_PX, REID_PX = 2, 200, 16, 25
MAX_MISS, MAX_MISS_UNCONF, MAX_MISS_KEEP = 6, 3, 10
CONFIRM_HITS, MERGE_ADJ_GAP, MERGE_PX, MERGE_Y_OVERLAP, MERGE_AREA_HI = 2, 0, 14, 80, 170
NEWTRK_IOU, AREA_LO, AREA_HI = 320, 50, 200
ETA_X0, ETA_Y0, ETA_X1, ETA_Y1 = 24, 24, 72, 72
NEAR_PCT, ARATE_MIN = 55, 6

def iou(d, b):
    ix0, iy0 = max(d["x0"], b[0]), max(d["y0"], b[1])
    ix1, iy1 = min(d["x1"], b[2]), min(d["y1"], b[3])
    if ix1 < ix0 or iy1 < iy0: return 0
    inter = (ix1-ix0+1)*(iy1-iy0+1)
    ua = inter + d["area"] + (b[2]-b[0]+1)*(b[3]-b[1]+1) - inter
    return 0 if ua <= 0 else inter*1000//ua

def predict(t, damp_n, damp_d):
    sx = t["vx"]*damp_n//(16*damp_d); sy = t["vy"]*damp_n//(16*damp_d)
    return [t["x0"]+sx, t["y0"]+sy, t["x1"]+sx, t["y1"]+sy], t["cx"]+sx, t["cy"]+sy

def run(frames, cfg):
    damp_n, damp_d = cfg["damp"]
    trks, next_id = [], 0
    nd_hist, nt_hist, ids = [], [], {}
    for f in sorted(frames):
        dets = frames[f]
        used_d = [False]*len(dets); used_t = [False]*len(trks)
        # pass1: IoU
        while True:
            best, bd, bt = -1, -1, -1
            for k, t in enumerate(trks):
                if used_t[k]: continue
                b4, pcx, pcy = predict(t, damp_n, damp_d)
                for i, d in enumerate(dets):
                    if used_d[i]: continue
                    v = iou(d, b4)
                    if v > best: best, bd, bt = v, i, k
            if best < IOU_THR or bd < 0: break
            used_d[bd] = used_t[bt] = True
            upd(trks[bt], dets[bd])
        # pass2: 质心距离
        while True:
            best, bd, bt = 1 << 20, -1, -1
            for k, t in enumerate(trks):
                if used_t[k]: continue
                b4, pcx, pcy = predict(t, damp_n, damp_d)
                for i, d in enumerate(dets):
                    if used_d[i]: continue
                    dx, dy = abs(d["cx"]-pcx), abs(d["cy"]-pcy)
                    dist = (dx if dx > dy else dy) + ((dx+dy) >> 2)
                    ratio = d["area"]*100//(t["area"] or 1)
                    if ratio < AREA_LO or ratio > AREA_HI: continue
                    if dist < best: best, bd, bt = dist, i, k
            if bd < 0: break
            gate = REID_PX if (trks[bt]["confirmed"] and trks[bt]["misses"] > 0) else GATE_PX
            if best > gate: break
            used_d[bd] = used_t[bt] = True
            upd(trks[bt], dets[bd])
        # 未匹配航迹
        for k, t in enumerate(trks):
            if used_t[k]: continue
            t["misses"] += 1; t["age"] += 1
            t["active"] = 1 if t["misses"] <= 1 else 0
            t["x0"] += t["vx"]//16; t["x1"] += t["vx"]//16
            t["y0"] += t["vy"]//16; t["y1"] += t["vy"]//16
            t["cx"] = min(95, max(0, t["cx"]+t["vx"]//16)); t["cy"] = min(95, max(0, t["cy"]+t["vy"]//16))
        # 新建
        for i, d in enumerate(dets):
            if used_d[i]: continue
            dup = False
            for k, t in enumerate(trks):
                if not (t["confirmed"] and t["active"]): continue
                b4, _, _ = predict(t, damp_n, damp_d)
                if iou(d, b4) >= NEWTRK_IOU: dup = True; break
            if dup: continue
            if cfg["gate"]:
                bw = d["x1"]-d["x0"]+1; bh = d["y1"]-d["y0"]+1
                if bw*10 >= 96*9 and bh*10 >= 96*9 and not cfg["person"]: continue
            if len(trks) >= MAX_TRK:
                victim = next((k for k, t in enumerate(trks) if not t["confirmed"]), -1)
                if victim < 0: continue
                del trks[victim]
            trks.append(dict(id=next_id, x0=d["x0"], y0=d["y0"], x1=d["x1"], y1=d["y1"],
                             cx=d["cx"], cy=d["cy"], vx=0, vy=0, area=d["area"],
                             hits=1, misses=0, age=1, confirmed=0, active=1))
            ids[next_id] = dict(first=f, last=f); next_id += 1
        # 合并（相邻两半 / 距离）+ 删除
        for a in range(len(trks)):
            for b in range(a+1, len(trks)):
                A, B = trks[a], trks[b]
                if A["misses"] or B["misses"]: continue
                ha = A["y1"]-A["y0"]+1; hb = B["y1"]-B["y0"]+1; hmin = min(ha, hb)
                oy0, oy1 = max(A["y0"], B["y0"]), min(A["y1"], B["y1"])
                gap = B["x0"]-A["x1"]-1 if B["x0"] > A["x1"] else (A["x0"]-B["x1"]-1 if A["x0"] > B["x1"] else 0)
                if MERGE_ADJ_GAP > 0 and gap <= MERGE_ADJ_GAP and hmin > 0 and (oy1-oy0+1)*5 >= hmin*4:
                    B["misses"] = MAX_MISS+1; continue
                dx, dy = A["cx"]-B["cx"], A["cy"]-B["cy"]
                if dx*dx+dy*dy > MERGE_PX*MERGE_PX: continue
                ar, br = A["area"], B["area"]
                if ar <= 0 or br <= 0: continue
                if br*100 > ar*MERGE_AREA_HI or ar*100 > br*MERGE_AREA_HI: continue
                if oy1 < oy0 or hmin <= 0: continue
                if (oy1-oy0+1)*100 < hmin*MERGE_Y_OVERLAP: continue
                keep, drop = (A, B) if A["hits"] >= B["hits"] else (B, A)
                keep["hits"] += drop["hits"]//2
                keep["age"] = max(keep["age"], drop["age"])
                drop["misses"] = MAX_MISS+1
        # 删除
        keep = []
        for t in trks:
            lim = MAX_MISS_UNCONF
            if t["confirmed"]:
                lim = MAX_MISS_KEEP if (cfg["keep"] and cfg["person"]) else MAX_MISS
            if t["misses"] > lim:
                continue
            keep.append(t)
        trks = keep
        for t in trks:
            ids.setdefault(t["id"], dict(first=f, last=f))["last"] = f
            if t["active"]: nt_hist.append(1)
        nt_hist.append(len([t for t in trks if t["active"]]))
        nd_hist.append(len(dets))
    life = [v["last"]-v["first"]+1 for v in ids.values()]
    life.sort()
    med = life[len(life)//2] if life else 0
    return dict(ids=len(ids), life_med=med, life_max=max(life) if life else 0,
                nt_med=sorted(nt_hist)[len(nt_hist)//2] if nt_hist else 0,
                nt_max=max(nt_hist) if nt_hist else 0,
                nd_med=sorted(nd_hist)[len(nd_hist)//2] if nd_hist else 0,
                frames=len(frames))

def upd(t, d):
    t["vx"] = (t["vx"]*3 + (d["cx"]-t["cx"])*16)//4
    t["vy"] = (t["vy"]*3 + (d["cy"]-t["cy"])*16)//4
    full = (d["x1"]-d["x0"]+1) > 96*4//5 and (d["y1"]-d["y0"]+1) > 96*4//5
    if full: t["vx"] = t["vy"] = 0
    t.update(x0=d["x0"], y0=d["y0"], x1=d["x1"], y1=d["y1"], cx=d["cx"], cy=d["cy"], area=d["area"])
    t["hits"] += 1; t["age"] += 1; t["misses"] = 0
    if t["hits"] >= CONFIRM_HITS: t["confirmed"] = 1
    t["active"] = 1

def load(path):
    frames, person = {}, {}
    for line in Path(path).read_text(encoding="utf-8", errors="replace").splitlines():
        m = TRK.search(line)
        if m:
            g = [int(x) for x in m.groups()]
            f, x0, y0, x1, y1 = g[0], g[4], g[5], g[6], g[7]
            frames.setdefault(f, []).append(dict(x0=x0, y0=y0, x1=x1, y1=y1,
                cx=(x0+x1)//2, cy=(y0+y1)//2, area=(x1-x0+1)*(y1-y0+1)))
            continue
        m = DEC.search(line)
        if m: person[int(m.group(1))] = int(m.group(2)) == 1
    return frames, person

CFG = {
  "基线（全速外推）": dict(damp=(1,1), gate=False, keep=False),
  "v17（1/2 阻尼）": dict(damp=(1,2), gate=False, keep=False),
  "v17+v16 GATE": dict(damp=(1,2), gate=True, keep=False),
  "v17+v16 GATE+KEEP": dict(damp=(1,2), gate=True, keep=True),
}

rows = []
for path in sys.argv[1:]:
    if path.startswith("--"): continue
    frames, person = load(path)
    if not frames: continue
    for name, cfg in CFG.items():
        r = run(frames, dict(cfg, person=any(person.values())))
        rows.append((Path(path).parent.name, name, r))

print("| 日志 | 配置 | 帧数 | 检测数中位 | ID 总数 | 中位存活(帧) | 最长存活 | nt 中位/最大 |")
print("|---|---|---|---|---|---|---|---|")
for log, name, r in rows:
    print("| %s | %s | %d | %d | %d | %d | %d | %d/%d |" % (
        log, name, r["frames"], r["nd_med"], r["ids"], r["life_med"], r["life_max"], r["nt_med"], r["nt_max"]))
