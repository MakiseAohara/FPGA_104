"""web_monitor.py - 实时监控 + 事件上报（PC 端）

两种输入可同时开：
  ① 串口：py -3 tools/web_monitor.py --port COM15 --http 8080 --out out/live
  ② UDP ：py -3 tools/web_monitor.py --udp 8080 --http 8081 --out out/live
  ③ 同时：--port COM15 --udp 8080

UDP 事件包格式见 evidence/eth_rgmii/UDP_EVENT_FORMAT.md；
页面唯一来源 tools/page.html。
"""
import argparse, json, struct, threading, time, zlib, socket
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import re

ap = argparse.ArgumentParser()
ap.add_argument("--port", default=None, help="串口端口，例如 COM15（不给则不开串口）")
ap.add_argument("--udp", type=int, default=None, help="UDP 监听端口，例如 8080（不给则不开 UDP）")
ap.add_argument("--http", type=int, default=8080)
ap.add_argument("--out", type=Path, default=Path("out/live"))
a = ap.parse_args()
if a.port is None and a.udp is None:
    a.port = "COM15"
a.out.mkdir(parents=True, exist_ok=True)

stats = dict(frames=0, person=0, motion=0, lp=0, alarm_starts=0,
             udp_events=0, udp_heartbeats=0, thumb_incomplete=0,
             started=time.strftime("%Y-%m-%dT%H:%M:%S"))
state = dict(t=0, f=0, p=-128, person=0, motion=0, area=0, ir=0, alarm=0, lowpwr=0, paused=0,
             camfps=0, inf_hz=0, sht=0, rh=0, body=0, nt=0, obs=0, nd=0,
             events=[], frame_png=None, last=0, ts=0, series=[], link="")
events = []
frame_png = [None]
lock = threading.Lock()

def png_gray(buf, w, h, scale=4):
    W, H = w * scale, h * scale
    rows = []
    for y in range(H):
        src = buf[(y // scale) * w:(y // scale + 1) * w]
        row = bytearray()
        for x in range(w):
            row += bytes([src[x]]) * scale
        rows.append(b"\x00" + bytes(row))
    raw = b"".join(rows)
    def ch(t, d):
        c = t + d
        return struct.pack(">I", len(d)) + c + struct.pack(">I", zlib.crc32(c) & 0xffffffff)
    return (b"\x89PNG\r\n\x1a\n" + ch(b"IHDR", struct.pack(">IIBBBBB", W, H, 8, 0, 0, 0, 0))
            + ch(b"IDAT", zlib.compress(raw, 6)) + ch(b"IEND", b""))

THUMB_DIR = a.out / "thumbs"
THUMB_DIR.mkdir(parents=True, exist_ok=True)

# ---------------- UDP 事件/缩略图 ----------------
MAGIC = b"MT"
KIND = {0: "NORMAL", 1: "INTRUDE", 2: "TREND", 3: "PERSON", 4: "LOWPWR"}
PKT_EVENT, PKT_HEARTBEAT, PKT_THUMB = 1, 2, 3
THUMB_W, THUMB_H = 96, 96
thumbs = {}   # id -> {"total":N, "parts":{seq:bytes}, "ts":ms, "last":time.time()}

def parse_hdr(d):
    if len(d) < 16:
        return None
    magic, ver, ptype = d[0:2], d[2], d[3]
    if magic != MAGIC or ver != 1:
        return None
    eid, seq, total, ts = struct.unpack(">IHHI", d[4:16])
    return dict(ptype=ptype, id=eid, seq=seq, total=total, ts=ts, payload=d[16:])

def save_thumb(eid):
    t = thumbs.get(eid)
    if not t:
        return None, False
    if t["total"] <= 0 or len(t["parts"]) != t["total"]:
        return None, False
    try:
        buf = b"".join(t["parts"][i] for i in range(1, t["total"] + 1))
    except KeyError:
        return None, False
    if len(buf) < THUMB_W * THUMB_H:
        return None, False
    data = png_gray(buf[:THUMB_W * THUMB_H], THUMB_W, THUMB_H, 2)
    p = THUMB_DIR / ("%s_thumb_%d.png" % (time.strftime("%Y%m%d_%H%M%S"), eid))
    p.write_bytes(data)
    return p.name, True

def udp_handle(data):
    h = parse_hdr(data)
    if not h:
        return
    eid = h["id"]
    if h["ptype"] == PKT_HEARTBEAT:
        stats["udp_heartbeats"] += 1
        state["last"] = time.time()
        return
    if h["ptype"] == PKT_EVENT:
        pl = h["payload"]
        kind_code = pl[0] if len(pl) >= 1 else 0
        x = pl[1] if len(pl) >= 2 else 0
        y = pl[2] if len(pl) >= 3 else 0
        conf = pl[3] if len(pl) >= 4 else 0
        obs = pl[4] if len(pl) >= 5 else 0
        stats["udp_events"] += 1
        state["last"] = time.time()
        add_event(KIND.get(kind_code, "EVT%d" % kind_code),
                  dict(x=x, y=y, conf=conf, obs=obs, ts_ms=h["ts"]), eid=eid)
        return
    if h["ptype"] == PKT_THUMB:
        t = thumbs.setdefault(eid, dict(total=h["total"], parts={}, ts=h["ts"], last=time.time()))
        t["total"] = h["total"]
        t["last"] = time.time()
        t["parts"][h["seq"]] = h["payload"][:1000]
        thumb, complete = save_thumb(eid)
        if complete:
            for ev in events:
                if ev.get("id") == eid:
                    ev["thumb"] = thumb
                    break
            add_event("THUMB", dict(ts_ms=h["ts"], complete=True), eid=eid, thumb=thumb)
            thumbs.pop(eid, None)
        return

def udp_loop():
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind(("0.0.0.0", a.udp))
    print("UDP 监听 0.0.0.0:%d" % a.udp, flush=True)
    while True:
        try:
            data, addr = s.recvfrom(4096)
        except Exception:
            continue
        try:
            udp_handle(data)
        except Exception as e:
            print("udp err", e, flush=True)

# ---------------- 事件与串口 ----------------
def add_event(kind, detail, eid=None, thumb=None, incomplete=False):
    ts_name = time.strftime("%Y%m%d_%H%M%S")
    th = thumb
    if th is None and frame_png[0]:
        p = THUMB_DIR / ("%s_%s.png" % (ts_name, kind))
        p.write_bytes(frame_png[0])
        th = p.name
    if th and "/" in th:
        th = th.rsplit("/", 1)[1]
    ev = dict(kind=kind, ts=time.strftime("%Y-%m-%dT%H:%M:%S"), wall=time.time(),
              time=time.strftime("%H:%M:%S"), detail=detail, thumb=th)
    for k in ("x", "y", "conf", "obs"):
        if k in detail:
            ev[k] = detail[k]
    if eid is not None:
        ev["id"] = eid
    if incomplete:
        ev["thumb_incomplete"] = True
    with lock:
        events.append(ev)
        del events[:-200]
        with (a.out / "events.jsonl").open("a", encoding="utf-8") as f:
            f.write(json.dumps(ev, ensure_ascii=False) + "\n")
    return ev

def finalize_stale_thumbs():
    """超时未收齐的分片：标记“缩略图不全”，不丢弃。"""
    while True:
        time.sleep(1)
        now = time.time()
        for eid, t in list(thumbs.items()):
            if now - t["last"] > 3:
                stats["thumb_incomplete"] += 1
                for ev in events:
                    if ev.get("id") == eid:
                        ev["thumb_incomplete"] = True
                        break
                add_event("THUMB", dict(ts_ms=t["ts"], got=len(t["parts"]), total=t["total"]),
                          eid=eid, incomplete=True)
                thumbs.pop(eid, None)

def reader():
    import serial
    with serial.Serial(a.port, 115200, timeout=0.05) as port:
        port.reset_input_buffer()
        buf = bytearray()
        while True:
            chunk = port.read(max(1, port.in_waiting))
            if not chunk:
                continue
            buf.extend(chunk)
            while b"\n" in buf:
                line, tail = buf.split(b"\n", 1)
                buf[:] = tail
                s = line.decode("ascii", errors="replace").rstrip("\r")
                handle(s)

def handle(s):
    state["ts"] = time.time()
    m = re.search(r"MMT_DEC t=(\d+) f=(\d+).*?motion=(\d) irhot=(\d) area=(\d+).*?person=(\d) ir_cnt=(\d+)", s)
    if m:
        state.update(t=int(m.group(1)), f=int(m.group(2)), motion=int(m.group(3)),
                     area=int(m.group(5)), person=int(m.group(6)), ir=int(m.group(7)))
        state["last"] = time.time()
        stats["frames"] += 1
        if state["person"]: stats["person"] += 1
        if state["motion"]: stats["motion"] += 1
        if state["lowpwr"]: stats["lp"] += 1
        return
    m = re.search(r"MMT_MOT f=(\d+) nd=(\d+) nt=(\d+)", s)
    if m:
        state.update(nd=int(m.group(2)), nt=int(m.group(3)))
        state["series"].append(dict(f=int(m.group(1)), n=int(m.group(2)), nt=int(m.group(3)), obs=state["obs"]))
        del state["series"][:-600]
        return
    m = re.search(r"MMT_MOT f=\d+ .*? obs=(-?\d+)", s)
    if m:
        state["obs"] = int(m.group(1))
        if state["series"]:
            state["series"][-1]["obs"] = state["obs"]
        return
    m = re.search(r"MMT_AI f=\d+ p=(-?\d+)", s)
    if m:
        state["p"] = int(m.group(1)); return
    m = re.search(r"MMT_ALARM (start|end)", s)
    if m:
        state["alarm"] = 1 if m.group(1) == "start" else 0
        if m.group(1) == "start":
            stats["alarm_starts"] += 1
        add_event("alarm_" + m.group(1), dict(f=state["f"], person=state["person"], p=state["p"]))
        return
    m = re.search(r"lowpwr=(\d) fw_lp=(\d) paused=(\d) camfps=(\d+) inf_hz=(\d+)", s)
    if m:
        prev = state["lowpwr"]
        state.update(lowpwr=int(m.group(1)), paused=int(m.group(3)), camfps=int(m.group(4)), inf_hz=int(m.group(5)))
        if prev == 0 and state["lowpwr"] == 1:
            add_event("lowpwr_enter", dict(f=state["f"]))
        if prev == 1 and state["lowpwr"] == 0:
            add_event("lowpwr_exit", dict(f=state["f"]))
        return
    m = re.search(r"sht=(\d+) rh=(\d+) body=(\d+)", s)
    if m:
        state.update(sht=int(m.group(1)), rh=int(m.group(2)), body=int(m.group(3))); return
    m = re.search(r"MMT_THUMB t=\d+ f=\d+ alarm=\d+ p=-?\d+ ([0-9a-f]{4608})", s)
    if m:
        raw = bytes.fromhex(m.group(1))
        frame_png[0] = png_gray(raw, 48, 48, 4)
        return

PAGE_PATH = Path(__file__).with_name("page.html")
PAGE = PAGE_PATH.read_text(encoding="utf-8") if PAGE_PATH.exists() else "<h1>page.html missing</h1>"

class H(BaseHTTPRequestHandler):
    def log_message(self, *x):
        pass
    def _send(self, body, ctype="application/json; charset=utf-8", code=200):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def do_GET(self):
        if self.path.startswith("/api/state"):
            with lock:
                ev = events[-60:]
                ser = state["series"][-240:]
            body = json.dumps(dict(
                f=state["f"], p=state["p"], person=state["person"], motion=state["motion"],
                area=state["area"], ir=state["ir"], alarm=state["alarm"], lowpwr=state["lowpwr"],
                paused=state["paused"], camfps=state["camfps"], inf_hz=state["inf_hz"],
                sht=state["sht"], rh=state["rh"], body=state["body"], nt=state["nt"], obs=state["obs"],
                nd=state["nd"], last=state["last"], ts=state["ts"], link=state["link"],
                frames=stats["frames"], alarm_starts=stats["alarm_starts"],
                udp_events=stats["udp_events"], udp_heartbeats=stats["udp_heartbeats"],
                thumb_incomplete=stats["thumb_incomplete"],
                events=ev, series=ser), ensure_ascii=False).encode()
            self._send(body); return
        if self.path.startswith("/api/status"):
            body = json.dumps({k: v for k, v in state.items() if k not in ("events", "frame_png")}, ensure_ascii=False).encode()
            self._send(body); return
        if self.path.startswith("/api/summary"):
            total = max(1, stats["frames"])
            body = json.dumps(dict(stats, person_pct=round(100.0*stats["person"]/total, 1),
                                   motion_pct=round(100.0*stats["motion"]/total, 1),
                                   lp_pct=round(100.0*stats["lp"]/total, 1)), ensure_ascii=False).encode()
            self._send(body); return
        if self.path.startswith("/api/events"):
            body = json.dumps(events[-50:], ensure_ascii=False).encode()
            self._send(body); return
        if self.path.startswith("/frame.png"):
            data = frame_png[0] or b""
            self._send(data, "image/png", 200 if data else 404); return
        if self.path.startswith("/thumb/"):
            name = self.path.split("/thumb/", 1)[1].split("?")[0].rsplit("/", 1)[-1]
            p = (THUMB_DIR / name)
            if p.exists():
                self._send(p.read_bytes(), "image/png"); return
            self._send(b"", "image/png", 404); return
        self._send(PAGE.encode(), "text/html; charset=utf-8")

if a.port:
    threading.Thread(target=reader, daemon=True).start()
if a.udp:
    threading.Thread(target=udp_loop, daemon=True).start()
threading.Thread(target=finalize_stale_thumbs, daemon=True).start()

state["link"] = ("串口+UDP" if (a.port and a.udp) else ("串口" if a.port else "UDP"))
state["ts"] = time.time()
print("HTTP http://127.0.0.1:%d/  串口 %s  UDP %s  事件日志 %s"
      % (a.http, a.port or "-", a.udp or "-", a.out / "events.jsonl"), flush=True)
ThreadingHTTPServer(("0.0.0.0", a.http), H).serve_forever()
