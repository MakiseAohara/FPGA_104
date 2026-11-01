"""web_monitor.py - 实时监控 + 事件上报（PC 端）

把板子的串口变成：① 事件上报（JSON 行，含类型/时间/位置/置信度/缩略图）② 浏览器可看的实时页面。
用法： py -3 tools\web_monitor.py --port COM15 --http 8080 --out out/live
"""
import argparse, json, struct, threading, time, zlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import re

ap = argparse.ArgumentParser()
ap.add_argument("--port", default="COM15")
ap.add_argument("--http", type=int, default=8080)
ap.add_argument("--out", type=Path, default=Path("out/live"))
a = ap.parse_args()
a.out.mkdir(parents=True, exist_ok=True)

stats = dict(frames=0, person=0, motion=0, lp=0, alarm_starts=0, started=time.strftime("%Y-%m-%dT%H:%M:%S"))
state = dict(t=0, f=0, p=-128, person=0, motion=0, area=0, ir=0, alarm=0, lowpwr=0, paused=0,
             camfps=0, inf_hz=0, sht=0, rh=0, body=0, events=[], frame_png=None, last=0)
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

def add_event(kind, detail):
    ts_name = time.strftime("%Y%m%d_%H%M%S")
    thumb = ""
    if frame_png[0]:
        p = THUMB_DIR / ("%s_%s.png" % (ts_name, kind))
        p.write_bytes(frame_png[0])
        thumb = str(p.as_posix())
    ev = dict(kind=kind, ts=time.strftime("%Y-%m-%dT%H:%M:%S"), wall=time.time(),
              detail=detail, thumb=thumb)
    events.append(ev)
    del events[:-200]
    with (a.out / "events.jsonl").open("a", encoding="utf-8") as f:
        f.write(json.dumps(ev, ensure_ascii=False) + "\n")

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

PAGE = """<!doctype html><meta charset=utf-8><title>MMT 实时监控</title>
<style>body{background:#111;color:#ddd;font:14px/1.5 Consolas,monospace;margin:16px}
.box{border:1px solid #333;padding:10px;margin-bottom:10px;border-radius:6px}
img{image-rendering:pixelated;border:1px solid #333;width:384px}
.alarm{color:#f55;font-weight:bold}.ok{color:#5f5}.lp{color:#fc5}
table{border-collapse:collapse}td{padding:2px 10px}</style>
<body><h2>MMT 多模态终端 · 实时监控</h2>
<div class=box><img id=fr src=/frame.png><div id=st>...</div></div>
<div class=box><b>统计</b><div id=sm></div></div>\n<div class=box><b>最近事件</b><div id=ev></div></div>
<script>
async function tick(){
 try{const r=await fetch("/api/status");const j=await r.json();
  document.getElementById("st").innerHTML=
   "帧 "+j.f+" · p="+j.p+" · person="+j.person+" · motion="+j.motion+" · area="+j.area+
   "<br>ALARM "+(j.alarm?"<span class=alarm>ON</span>":"<span class=ok>off</span>")+
   " · LOWPWR "+(j.lowpwr?"<span class=lp>ON</span>":"off")+
   " · camfps="+j.camfps+" · inf_hz="+j.inf_hz+
   "<br>温度 "+j.sht+" · 湿度 "+j.rh+" · 体表 "+j.body;
  document.getElementById("fr").src="/frame.png?t="+Date.now();
  const sm=await (await fetch("/api/summary")).json();
  document.getElementById("sm").innerHTML="统计自 "+sm.started+"：帧 "+sm.frames+" · 有人帧 "+sm.person+" ("+sm.person_pct+"%) · 运动帧 "+sm.motion+" ("+sm.motion_pct+"%)<br>报警起报 "+sm.alarm_starts+" 次 · 低功耗帧 "+sm.lp+" ("+sm.lp_pct+"%)";
  const e=await (await fetch("/api/events")).json();
  document.getElementById("ev").innerHTML=e.slice(-12).reverse().map(x=>x.ts+" "+x.kind).join("<br>");
 }catch(e){}
 setTimeout(tick,700);}
tick();
</script>"""

class H(BaseHTTPRequestHandler):
    def log_message(self, *x):
        pass
    def do_GET(self):
        if self.path.startswith("/api/status"):
            body = json.dumps({k: v for k, v in state.items() if k not in ("events", "frame_png")}, ensure_ascii=False).encode()
            self.send_response(200); self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body); return
        if self.path.startswith("/api/summary"):
            total = max(1, stats["frames"])
            body = json.dumps(dict(stats, person_pct=round(100.0*stats["person"]/total,1),
                                   motion_pct=round(100.0*stats["motion"]/total,1),
                                   lp_pct=round(100.0*stats["lp"]/total,1)), ensure_ascii=False).encode()
            self.send_response(200); self.send_header("Content-Type","application/json; charset=utf-8")
            self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body); return
        if self.path.startswith("/api/events"):
            body = json.dumps(events[-50:], ensure_ascii=False).encode()
            self.send_response(200); self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body); return
        if self.path.startswith("/frame.png"):
            data = frame_png[0] or b""
            self.send_response(200 if data else 404); self.send_header("Content-Type", "image/png")
            self.send_header("Content-Length", str(len(data))); self.end_headers(); self.wfile.write(data); return
        body = PAGE.encode()
        self.send_response(200); self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)

threading.Thread(target=reader, daemon=True).start()
print("HTTP http://127.0.0.1:%d/  串口 %s  事件日志 %s" % (a.http, a.port, a.out / "events.jsonl"), flush=True)
ThreadingHTTPServer(("0.0.0.0", a.http), H).serve_forever()