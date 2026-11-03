#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""acceptance.py - 网口上报验收：只听 8080，按 UDP_EVENT_FORMAT v1 检查格式/节奏/完整性。
用法: py -3 tools/acceptance.py --secs 30 [--json out/accept.json]
"""
import argparse, json, socket, struct, time
from pathlib import Path

ap = argparse.ArgumentParser()
ap.add_argument("--port", type=int, default=8080)
ap.add_argument("--secs", type=int, default=30)
ap.add_argument("--json", type=Path, default=None)
a = ap.parse_args()

s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("0.0.0.0", a.port)); s.settimeout(1.0)

st = dict(t0=time.time(), hb=[], ev=[], th={}, bad=0, lens=set(), types={})
t0 = time.time()
while time.time() - t0 < a.secs:
    try:
        d, addr = s.recvfrom(4096)
    except socket.timeout:
        continue
    if len(d) < 16 or d[0:2] != b"MT" or d[2] != 1:
        st["bad"] += 1
        continue
    ty = d[3]
    eid, seq, total, ts = struct.unpack(">IHHI", d[4:16])
    st["types"][ty] = st["types"].get(ty, 0) + 1
    if ty == 2:                       # 心跳
        st["hb"].append(time.time())
        st["lens"].add(len(d))
    elif ty == 1:                     # 事件
        body = d[16:]
        st["ev"].append(dict(t=time.time(), eid=eid, kind=body[0] if body else -1,
                             x=body[1] if len(body) > 1 else -1, y=body[2] if len(body) > 2 else -1,
                             conf=body[3] if len(body) > 3 else -1, obs=body[4] if len(body) > 4 else -1,
                             blen=len(body), total=total))
    elif ty == 3:                     # 缩略图分片
        e = st["th"].setdefault(eid, dict(total=total, got={}, t0=time.time()))
        e["got"][seq] = len(d) - 16
        e["total"] = total

dur = time.time() - t0
hb = st["hb"]
gaps = [hb[i+1] - hb[i] for i in range(len(hb) - 1)]
ev_ok = [e for e in st["ev"] if e["blen"] == 5 and e["total"] == 1 and 0 <= e["kind"] <= 4]
ev_bad = [e for e in st["ev"] if e not in ev_ok]
th = st["th"]
full = {k: v for k, v in th.items() if len(v["got"]) == v["total"] and v["total"] > 0}
lossy = {k: v for k, v in th.items() if len(v["got"]) < v["total"]}

rep = {
    "dur_s": round(dur, 1),
    "packets": sum(st["types"].values()),
    "bad_packets": st["bad"],
    "by_type": st["types"],
    "hb_count": len(hb),
    "hb_len": sorted(st["lens"]),
    "hb_gap_med_s": round(sorted(gaps)[len(gaps)//2], 3) if gaps else None,
    "hb_gap_max_s": round(max(gaps), 3) if gaps else None,
    "event_count": len(st["ev"]),
    "event_schema_ok": len(ev_ok),
    "event_schema_bad": len(ev_bad),
    "thumb_sets": len(th),
    "thumb_complete": len(full),
    "thumb_lossy": len(lossy),
    "thumb_chunk_lens": sorted({l for v in th.values() for l in v["got"].values()}),
}
checks = [
    ("包头魔数/版本", st["bad"] == 0),
    ("心跳长度 18 B", st["lens"] == {18}),
    ("心跳节奏 2 s", bool(gaps) and 1.4 <= rep["hb_gap_med_s"] <= 2.6),
    ("事件负载 5 B", rep["event_schema_bad"] == 0),
    ("缩略图 10 片齐全", len(lossy) == 0 if th else True),
    ("分片大小 1000/216", set(rep["thumb_chunk_lens"]) <= {1000, 216}),
]
print(json.dumps(rep, ensure_ascii=False, indent=1))
print("\n验收项:")
allpass = True
for name, ok in checks:
    allpass &= ok
    print("  [%s] %s" % ("PASS" if ok else "FAIL", name))
print("\n总判定:", "PASS" if allpass else "FAIL")
if a.json:
    a.json.parent.mkdir(parents=True, exist_ok=True)
    a.json.write_text(json.dumps(dict(rep, checks=dict(checks), verdict="PASS" if allpass else "FAIL"),
                                 ensure_ascii=False, indent=1), encoding="utf-8")
    print("写入", a.json)
