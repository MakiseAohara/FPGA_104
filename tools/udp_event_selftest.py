"""udp_event_selftest.py - UDP 事件包自测（本机发送模拟包，验证重组与落盘）

覆盖：正常事件、缩略图乱序重组、重复分片、缺片（缩略图不全）、心跳。
用法： py -3 tools/udp_event_selftest.py
"""
import json, os, socket, struct, subprocess, sys, time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "out" / "live_selftest"
UDP_PORT = 18080
HTTP_PORT = 18081
MAGIC = b"MT"
PKT_EVENT, PKT_HEARTBEAT, PKT_THUMB = 1, 2, 3

def hdr(ptype, eid, seq=0, total=1, ts=0):
    return MAGIC + bytes([1, ptype]) + struct.pack(">IHHI", eid, seq, total, ts)

def event_pkt(eid, kind=1, x=30, y=40, conf=77, obs=1, ts=12345):
    return hdr(PKT_EVENT, eid, total=1, ts=ts) + bytes([kind, x, y, conf, obs])

def thumb_pkts(eid, data=None, chunk=1000, drop=0, dup=0):
    if data is None:
        data = bytes(((i * 7) % 256) for i in range(96 * 96))
    parts = [data[i:i + chunk] for i in range(0, len(data), chunk)]
    total = len(parts)
    out = []
    for i, p in enumerate(parts, start=1):
        out.append(hdr(PKT_THUMB, eid, seq=i, total=total, ts=999) + p)
    if drop:
        out = out[:-drop]
    if dup and len(out) > dup:
        out.insert(2, out[dup])       # 重复一片
    return out

def main():
    if OUT.exists():
        for f in OUT.rglob("*"):
            if f.is_file():
                f.unlink()
    OUT.mkdir(parents=True, exist_ok=True)
    py = sys.executable
    proc = subprocess.Popen([py, str(ROOT / "tools" / "web_monitor.py"),
                             "--udp", str(UDP_PORT), "--http", str(HTTP_PORT), "--out", str(OUT)],
                            cwd=str(ROOT), stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    time.sleep(2.0)
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    dst = ("127.0.0.1", UDP_PORT)
    try:
        # 1) 正常事件 + 乱序缩略图
        s.sendto(event_pkt(1001, kind=1, x=30, y=40, conf=77, obs=2), dst)
        pk = thumb_pkts(1001, dup=2)
        random_ord = pk[::-1]
        for p in random_ord:
            s.sendto(p, dst)
            time.sleep(0.01)
        # 2) 缺片事件（少 1 片）
        s.sendto(event_pkt(1002, kind=3, x=10, y=20, conf=55, obs=1), dst)
        for p in thumb_pkts(1002, drop=1):
            s.sendto(p, dst)
        time.sleep(0.05)
        # 3) 心跳
        s.sendto(hdr(PKT_HEARTBEAT, 0), dst)
        time.sleep(0.05)
        # 4) 完全不带缩略图的事件
        s.sendto(event_pkt(1003, kind=4, x=0, y=0, conf=10, obs=0), dst)
        time.sleep(6.0)
    finally:
        s.close()
        time.sleep(0.5)
        proc.terminate()
        try:
            proc.wait(timeout=5)
        except Exception:
            proc.kill()

    # ---- 校验 ----
    log = OUT / "events.jsonl"
    th = OUT / "thumbs"
    rows = []
    if log.exists():
        rows = [json.loads(x) for x in log.read_text(encoding="utf-8").splitlines() if x.strip()]
    thumbs = sorted([p.name for p in th.glob("thumb_*.png")]) if th.exists() else []
    ok = True
    def chk(name, cond, extra=""):
        nonlocal ok
        print(("PASS  " if cond else "FAIL  ") + name + (("  " + extra) if extra else ""))
        if not cond:
            ok = False

    ids = [r.get("id") for r in rows]
    chk("事件落盘（3 条事件）", len([r for r in rows if r["kind"] in ("INTRUDE", "PERSON", "LOWPWR")]) >= 3,
        "events=%d" % len(rows))
    chk("事件 id 完整", set([1001, 1002, 1003]).issubset(set(ids)), "ids=%s" % sorted(set(ids)))
    r1001 = [r for r in rows if r.get("id") == 1001]
    chk("1001 事件类型/坐标/置信度/人数",
        bool(r1001) and r1001[0]["kind"] == "INTRUDE" and r1001[0]["detail"]["x"] == 30
        and r1001[0]["detail"]["conf"] == 77 and r1001[0]["detail"]["obs"] == 2)
    chk("1001 缩略图重组成功（乱序+重复）", any(r.get("id") == 1001 and r.get("thumb") for r in rows),
        "thumbs=%s" % thumbs[:3])
    chk("1001 缩略图文件存在", any(n == "thumb_1001.png" for n in thumbs))
    chk("1002 缺片被标记而不是丢弃", any(r.get("id") == 1002 and r.get("thumb_incomplete") for r in rows),
        "rows_1002=%s" % [r for r in rows if r.get("id") == 1002][:1])
    chk("1002 没有生成缩略图文件", not any(n == "thumb_1002.png" for n in thumbs))
    chk("1003 无缩略图事件仍落盘", any(r.get("id") == 1003 for r in rows))
    print("\nRESULT:", "ALL PASS" if ok else "FAILED")
    return 0 if ok else 1

if __name__ == "__main__":
    raise SystemExit(main())
