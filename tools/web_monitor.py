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
             camfps=0, inf_hz=0, sht=0, rh=0, body=0, events=[], frame_png=None, last=0,
             mot_nd=0, mot_nt=0, mot_conf=0, mot_obs=0,
             geo_fw=1920, geo_fh=1080, geo_bx=420, geo_by=0, geo_bw=1080, geo_bh=1080,
             alarm_nd=-1, alarm_nt=-1, alarm_conf=-1, full_thumb=0, connected=0, thumb_ts=0, fw_lp=0, irhot=0)
events = []
frame_png = [None]
lock = threading.Lock()

def png_gray(buf, w, h, scale=4, box=None):
    W, H = w * scale, h * scale
    img = bytearray(buf)
    if box and (box[2] < w * 0.98 or box[3] < h * 0.98):   # 整幅就不画框
        x0, y0, bw, bh = box
        xa = max(0, min(w - 1, int(round(x0))))
        xb = max(0, min(w - 1, int(round(x0 + bw))))
        ya = max(0, min(h - 1, int(round(y0))))
        yb = max(0, min(h - 1, int(round(y0 + bh))))
        for x in range(xa, xb + 1):
            v = 255 if (x % 2) == 0 else 0
            img[ya * w + x] = v
            img[yb * w + x] = v
        for y in range(ya, yb + 1):
            v = 255 if (y % 2) == 0 else 0
            img[y * w + xa] = v
            img[y * w + xb] = v
    rows = []
    for y in range(H):
        src = img[(y // scale) * w:(y // scale + 1) * w]
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

ERRLOG = a.out / "monitor_errors.log"
RAWLOG = a.out / "serial_raw.log"
_raw = RAWLOG.open("a", encoding="utf-8")

def raw_log(s):
    """原始串口落盘，带主机时间戳；长行（缩略图像素）截断，只留可分析部分。
       这样网页实时和事后分析用的是同一份数据，不必抢 COM15。"""
    s = s.replace("\r", " ").strip()          # 行首 CR 会把时间戳和内容拆成两行
    line = s if len(s) <= 300 else s[:300] + "..[trunc]"
    _raw.write("%.3f\t%s\n" % (time.time(), line))
    _raw.flush()

def log_err(what, exc, extra=""):
    try:
        with ERRLOG.open("a", encoding="utf-8") as fh:
            fh.write("%s %s %r %s\n" % (time.strftime("%Y-%m-%dT%H:%M:%S"), what, exc, extra[:160]))
    except Exception:
        pass

def reader():
    """读串口：解析异常只记日志不退出；串口异常自动重连。
       否则一次异常就会让读线程静默死掉，而 HTTP 还在服务旧数据 —— 页面看着"不准"。"""
    import serial
    while True:
        try:
            with serial.Serial(a.port, 115200, timeout=0.05) as port:
                port.reset_input_buffer()
                state["connected"] = 1
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
                        try:
                            raw_log(s)
                            handle(s)
                        except Exception as exc:
                            log_err("handle", exc, s)
        except Exception as exc:
            state["connected"] = 0
            log_err("serial", exc)
            time.sleep(2.0)

def handle(s):
    m = re.search(r"MMT_DEC t=(\d+) f=(\d+).*?motion=(\d) irhot=(\d) area=(\d+).*?person=(\d) ir_cnt=(\d+)", s)
    if m:
        state.update(t=int(m.group(1)), f=int(m.group(2)), motion=int(m.group(3)),
                     irhot=int(m.group(4)), area=int(m.group(5)), person=int(m.group(6)), ir=int(m.group(7)))
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
        cnt = re.search(r" nd=(\d+) nt=(\d+) conf=(\d+)", s)
        if cnt:
            state.update(alarm_nd=int(cnt.group(1)), alarm_nt=int(cnt.group(2)),
                         alarm_conf=int(cnt.group(3)))
        if m.group(1) == "start":
            stats["alarm_starts"] += 1
        add_event("alarm_" + m.group(1),
                  dict(f=state["f"], person=state["person"], p=state["p"],
                       nd=state.get("alarm_nd"), nt=state.get("alarm_nt"),
                       conf=state.get("alarm_conf")))
        return
    m = re.search(r"lowpwr=(\d) fw_lp=(\d) paused=(\d) camfps=(\d+) inf_hz=(\d+)", s)
    if m:
        prev = state["lowpwr"]
        state.update(lowpwr=int(m.group(1)), fw_lp=int(m.group(2)), paused=int(m.group(3)),
                     camfps=int(m.group(4)), inf_hz=int(m.group(5)))
        if prev == 0 and state["lowpwr"] == 1:
            add_event("lowpwr_enter", dict(f=state["f"]))
        if prev == 1 and state["lowpwr"] == 0:
            add_event("lowpwr_exit", dict(f=state["f"]))
        return
    m = re.search(r"sht=(\d+) rh=(\d+) body=(\d+)", s)
    if m:
        state.update(sht=int(m.group(1)), rh=int(m.group(2)), body=int(m.group(3))); return
    m = re.search(r"MMT_MOT f=(\d+) nd=(\d+) nt=(\d+) conf=(\d+)", s)
    if m:
        state.update(mot_nd=int(m.group(2)), mot_nt=int(m.group(3)), mot_conf=int(m.group(4)))
        ob = re.search(r" obs=(\d+)", s)
        if ob:
            state["mot_obs"] = int(ob.group(1))
        return
    m = re.search(r"MMT_THUMB_GEO fw=(\d+) fh=(\d+) bx=(-?\d+) by=(-?\d+) bw=(\d+) bh=(\d+)", s)
    if m:
        state.update(geo_fw=int(m.group(1)), geo_fh=int(m.group(2)), geo_bx=int(m.group(3)),
                     geo_by=int(m.group(4)), geo_bw=int(m.group(5)), geo_bh=int(m.group(6)))
        return
    m = re.search(r"MMT_THUMB t=\d+ f=\d+ alarm=\d+ p=-?\d+ ([0-9a-f]+)", s)
    if m:
        hx = m.group(1)
        if len(hx) == 2592:      tw, th = 48, 27      # 48x27 = 16:9 整幅
        elif len(hx) == 4608:    tw, th = 48, 48      # 旧版方阵（向后兼容）
        else:                    return
        raw = bytes.fromhex(hx)
        state['thumb_ts'] = time.time()
        box = None
        if state["geo_fw"] and state["geo_bw"]:
            kx = float(tw) / state["geo_fw"]; ky = float(th) / state["geo_fh"]
            box = (state["geo_bx"] * kx, state["geo_by"] * ky,
                   state["geo_bw"] * kx, state["geo_bh"] * ky)
            state["full_thumb"] = 1
        frame_png[0] = png_gray(raw, tw, th, 4, box=box)
        return

PAGE = """<!doctype html><meta charset=utf-8><title>MMT 实时监控</title>
<style>
body{background:#111;color:#ddd;font:15px/1.6 "Microsoft YaHei",Consolas,monospace;margin:16px;max-width:560px}
.box{border:1px solid #333;padding:12px;margin-bottom:10px;border-radius:8px}
img{image-rendering:pixelated;border:1px solid #333;width:100%;max-width:512px;display:block;margin:0 auto 10px}
#big{font-size:26px;font-weight:bold;text-align:center;padding:6px 0}
#sum{text-align:center;color:#aaa;font-size:15px}
.ok{color:#5f5}.warn{color:#f55}.idle{color:#fc5}.dim{color:#777}
details summary{cursor:pointer;color:#8ab}
td{padding:2px 12px;color:#bbb}
</style>
<body>
<h2>MMT 多模态终端 · 实时监控</h2>
<div class=box>
  <img id=fr src=/frame.png>
  <div id=imgage class=dim style="text-align:center;font-size:13px"></div>
  <div id=big>连接中…</div>
  <div id=sum></div>
</div>
<details class=box open><summary>画面里的目标</summary><div id=tgt class=dim>—</div></details>
<details class=box><summary>技术细节（后台数值）</summary><div id=tech class=dim>—</div></details>
<details class=box><summary>最近事件</summary><div id=ev class=dim>—</div></details>
<script>
function h(t){return t.replace(/&/g,"&amp;").replace(/</g,"&lt;")}
async function tick(){
 try{
  const j=await (await fetch("/api/status")).json();
  const age=(Date.now()/1000-j.last);
  const big=document.getElementById("big"), sum=document.getElementById("sum");

  const n=(typeof j.mot_obs==="number")?j.mot_obs:(j.mot_conf||0);
  if(age>3){
    big.className="warn"; big.textContent="数据中断 "+age.toFixed(1)+" 秒";
    sum.textContent="下面的数字都是旧的，请检查串口/板子";
  } else if(j.alarm){
    big.className="warn"; big.textContent="⚠ 报警中";
    sum.textContent="画面里 "+n+" 人 · 画面帧率 "+j.camfps;
  } else {
    const lp=(j.lowpwr||j.fw_lp);
    if(n>0){ big.className="ok"; big.textContent="画面里 "+n+" 人"; }
    else if(lp){ big.className="idle"; big.textContent="低功耗中 · 画面无人"; }
    else { big.className="ok"; big.textContent="正常 · 画面无人"; }
    sum.textContent="画面帧率 "+j.camfps+(lp?" · 推理已暂停":"");
  }

  document.getElementById("fr").src="/frame.png?t="+Date.now();
  const ia=(j.thumb_ts>0)?(Date.now()/1000-j.thumb_ts):-1;
  document.getElementById("imgage").textContent = ia<0 ? "" :
    "画面为 "+ia.toFixed(1)+" 秒前（下面的数值是实时的）";
  document.getElementById("tgt").innerHTML=
    "画面里的人数：<b>"+n+"</b>　<span class=dim>只数本帧真的看到、框够大的</span><br>"+
    "航迹表：<b>"+j.mot_nt+"</b> 条<span class=dim>（含正在丢失/噪点）</span>　检测框：<b>"+j.mot_nd+"</b><br>"+
    "最近一次报警时的检测人数：<b>"+(j.alarm_nd>=0?j.alarm_nd:"—")+"</b>"+
    (j.alarm_nt>=0?"（航迹 "+j.alarm_nt+"）":"");
  document.getElementById("tech").innerHTML=
    "<table><tr><td>AI 判人 / 画面人数</td><td>"+(j.person?"有人":"无人")+"　/　"+n+" 人</td></tr>"+
    "<tr><td>AI 人体分 p</td><td>"+j.p+"　(≥0 判有人)</td></tr>"+
    "<tr><td>运动 / 面积</td><td>"+(j.motion?"有":"无")+"　"+j.area+"</td></tr>"+
    "<tr><td>红外热点(irhot)</td><td>"+(j.irhot?"有":"无")+"</td></tr>"+
    "<tr><td>低功耗（固件/RTL）</td><td>"+(j.fw_lp?"开":"关")+"　/　"+(j.lowpwr?"开":"关")+"</td></tr>"+
    "<tr><td>推理</td><td>"+(j.paused?"已暂停":"运行中")+"</td></tr>"+
    "<tr><td>画面帧率 / 推理频率</td><td>"+j.camfps+"　/　"+j.inf_hz+" Hz</td></tr>"+
    "<tr><td>温度 / 湿度 / 体表</td><td>"+j.sht+" °C　"+j.rh+" %　"+j.body+"</td></tr>"+
    "<tr><td>数据延迟</td><td>"+age.toFixed(1)+" s</td></tr></table>";
  const e=await (await fetch("/api/events")).json();
  document.getElementById("ev").innerHTML=e.slice(-8).reverse()
    .map(x=>x.ts.replace("T"," ")+"　"+x.kind).join("<br>")||"—";
 }catch(e){}
 setTimeout(tick,400);
}
tick();
</script>"""

# 网页的唯一真相源：tools/page.html。存在就以文件为准（板端 HTTP 也用同一份文件生成），
# 这样"PC 上的页面"和"FPGA 里返回的页面"是同一串字节。
_page_file = Path(__file__).resolve().parent / "page.html"
if _page_file.exists():
    PAGE = _page_file.read_text(encoding="utf-8")

class H(BaseHTTPRequestHandler):
    def log_message(self, *x):
        pass
    def end_headers(self):
        self.send_header("Cache-Control", "no-store, no-cache, must-revalidate")
        self.send_header("Pragma", "no-cache")
        super().end_headers()

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