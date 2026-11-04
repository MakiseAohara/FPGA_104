"""web_monitor.py - 实时监控 + 事件上报（PC 端）

两种输入可同时开：
  ① 串口：py -3 tools/web_monitor.py --port COM15 --http 8080 --out out/live
  ② UDP ：py -3 tools/web_monitor.py --udp 8080 --http 8081 --out out/live
  ③ 同时：--port COM15 --udp 8080

UDP 事件包格式见 evidence/eth_rgmii/UDP_EVENT_FORMAT.md；
页面唯一来源 tools/page.html。
"""
import argparse, json, struct, threading, time, zlib, socket, copy, urllib.request, urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import re
from preview_protocol import decode_preview_packet,encode_preview_packet,MIME as PREVIEW_MIME


class BoardTrackParser:
    """Commit serial MOT snapshots only at MMT_MOT boundaries.

    The old f field may repeat across several tracking steps. It is retained
    as firmware_frame, never used as elapsed time or as an image match key.
    """
    def __init__(self):
        self.pending = {}
        self.pending_seq = None
        self.history = {}
        self.seen_at = {}
        self.commit = 0
        self.last_stamp = None
        self.last_seq = None
        self.snapshot = None
        self.prewarn = dict(active=False, id=None, eta_steps=-1, eta_ms=None,
                            action="none", timestamp_ms=None)

    @staticmethod
    def fields(line):
        return dict(re.findall(r"\b([A-Za-z_]\w*)=([^\s]+)", line))

    @staticmethod
    def number(fields, key, default=None):
        try:
            return int(fields[key])
        except (KeyError, TypeError, ValueError):
            return default

    @staticmethod
    def vector(fields, key, size):
        try:
            values = [int(v) for v in fields[key].split(",")]
            return values if len(values) == size else None
        except (KeyError, TypeError, ValueError):
            return None

    def _event_snapshot(self):
        if self.snapshot is None:
            return None
        snapshot = copy.deepcopy(self.snapshot)
        snapshot["prewarn"] = copy.deepcopy(self.prewarn)
        self.snapshot = snapshot
        return snapshot

    def feed(self, line):
        f = self.fields(line)
        if "MMT_BOOT" in line or "MMT_LIVE_BOOT" in line:
            self.__init__()
            return None
        if "MMT_PREWARN " in line:
            self.prewarn = dict(active=True, id=self.number(f, "id"),
                                eta_steps=self.number(f, "eta", -1), eta_ms=None,
                                action="prewarn_only", timestamp_ms=self.number(f, "t", self.number(f, "ms")))
            step = self.snapshot.get("time_step_ms") if self.snapshot else None
            if step and self.prewarn["eta_steps"] >= 0:
                self.prewarn["eta_ms"] = step * self.prewarn["eta_steps"]
            return self._event_snapshot()
        if "MMT_LP_EXIT " in line and f.get("reason") == "prewarn":
            self.prewarn = dict(self.prewarn, active=True, action="wake_inference",
                                timestamp_ms=self.number(f, "t", self.number(f, "ms")))
            return self._event_snapshot()
        if "MMT_TRK " in line:
            seq = self.number(f, "seq")
            if seq is not None and self.pending_seq is not None and seq != self.pending_seq:
                self.pending.clear()  # a summary line was lost: never mix steps
            if seq is not None:
                self.pending_seq = seq
            tid = self.number(f, "id")
            box, center, velocity, prediction = [self.vector(f, key, size) for key, size in
                                                (("b", 4), ("c", 2), ("v16", 2), ("pred", 2))]
            if tid is None or box is None or center is None or velocity is None or prediction is None:
                return None
            if box[0] > box[2] or box[1] > box[3] or not all(0 <= v <= 95 for v in box + center):
                return None
            miss = self.number(f, "miss", 0)
            support = self.number(f, "supported", self.number(f, "support"))
            self.pending[tid] = dict(id=tid, bbox=box, center=center, velocity_q4=velocity,
                                     prediction=prediction, future=[prediction],
                                     confirmed=bool(self.number(f, "conf", 0)),
                                     visible=miss == 0, misses=miss,
                                     hits=self.number(f, "hit", 0),
                                     state="observed" if miss == 0 else "coasting",
                                     supported=None if support is None else bool(support),
                                     eta_steps=self.number(f, "eta", -1),
                                     firmware_frame=self.number(f, "f"))
            return None
        if "MMT_MOT " not in line:
            return None
        seq = self.number(f, "seq")
        if seq is not None and self.last_seq is not None:
            advance = (seq - self.last_seq) & 0xFFFFFFFF
            if advance == 0 or advance >= 0x80000000:
                self.pending.clear()
                self.pending_seq = None
                return None
        if seq is not None:
            self.last_seq = seq
        self.commit += 1
        stamp = self.number(f, "t", self.number(f, "ms"))
        sample = self.number(f, "dt")
        if sample is None and stamp is not None and self.last_stamp is not None:
            elapsed = (stamp - self.last_stamp) & 0xFFFFFFFF
            if 0 < elapsed <= 10000:
                sample = elapsed
        if stamp is not None:
            self.last_stamp = stamp
        # New firmware must explicitly publish the velocity time base. Merely
        # seeing a sequence or timestamp is insufficient evidence of its units.
        step = self.number(f, "step_ms", self.number(f, "time_step_ms"))
        if step is None and f.get("algorithm") in ("timed_v1", "timed_mot_v1"):
            step = 200
        if step is not None and step <= 0:
            step = None
        current = list(self.pending.values()) if seq is None or self.pending_seq in (None, seq) else []
        count = self.number(f, "nt", len(current))
        if count <= 0:
            current = []
            self.history.clear()
            self.seen_at.clear()
        for t in current:
            tid = t["id"]
            self.seen_at[tid] = self.commit
            points = self.history.setdefault(tid, [])
            if t["visible"]:
                points.append(t["center"][:])
                del points[:-12]
            t["history"] = copy.deepcopy(points)
            t["eta_ms"] = t["eta_steps"] * step if step and t["eta_steps"] >= 0 else None
            t["warning"] = t["eta_steps"] >= 0 and t["supported"] is not False
        for tid in list(self.history):
            if self.commit - self.seen_at.get(tid, 0) > 12:
                self.history.pop(tid, None)
                self.seen_at.pop(tid, None)
        pre = self.number(f, "pre", 0)
        self.prewarn = dict(self.prewarn, active=bool(pre),
                            eta_steps=self.number(f, "pre_eta", -1))
        if not pre:
            self.prewarn.update(id=None, eta_ms=None, action="none")
        elif step and self.prewarn["eta_steps"] >= 0:
            self.prewarn["eta_ms"] = step * self.prewarn["eta_steps"]
        self.snapshot = dict(schema=1, source="board_telemetry",
                             algorithm="timed_board" if step else "legacy_board",
                             frame_id=seq if seq is not None else self.commit,
                             firmware_frame=self.number(f, "f"),
                             timestamp_ms=stamp, timestamp_source="device" if stamp is not None else "unknown",
                             sample_ms=sample, time_step_ms=step,
                             velocity_unit="px/time_step_q4" if step else "px/sample_q4",
                             width=96, height=96,people_count=self.number(f,"obs"),horizon_steps=2,
                             horizon_ms=2*step if step else None,
                             roi=[24,24,72,72], frame_url="/frame.png", frame_aligned=False,
                             image_note="串口缩略图未携带匹配的跟踪快照标识，轨迹使用独立坐标平面。",
                             tracks=current, prewarn=copy.deepcopy(self.prewarn),
                             metrics=dict(reported_tracks=len(current), visible_tracks=sum(t["visible"] for t in current)))
        self.pending.clear()
        self.pending_seq = None
        return self.snapshot

class BoardHTTPMirror:
    """Publish immutable state/image pairs from the FPGA HTTP endpoint.

    Serial and UDP remain event/fallback inputs; they never overwrite an aligned
    image. A stale FPGA snapshot token is rejected by firmware and retried.
    """
    def __init__(self, url):
        self.url=url.rstrip('/')
        parsed=urllib.parse.urlsplit(self.url)
        if parsed.scheme!='http' or not parsed.hostname or parsed.path not in ('','/'):
            raise ValueError('--board-url requires an http://host[:port] address')
        self.opener=urllib.request.build_opener(urllib.request.ProxyHandler({}))
        self.lock=threading.Lock();self.frames={};self.latest=None;self.updated=0;self.error=''
        self.pixels=None;self.packed_supported=None

    def read(self,path,limit):
        with self.opener.open(self.url+path,timeout=4) as response:
            data=response.read(limit+1)
            if len(data)>limit:raise ValueError('FPGA response exceeds limit')
            return data

    def poll_once(self):
        raw=None
        if self.packed_supported is not False:
            try:
                packet=self.read('/api/preview',32768)
                if packet[:4]==b'MMTP':
                    state,raw=decode_preview_packet(packet);self.packed_supported=True
                else:self.packed_supported=False
            except urllib.error.HTTPError as error:
                if error.code!=404:raise
                self.packed_supported=False
        if raw is None:state=json.loads(self.read('/api/state',16384))
        tracking=state.get('tracking')
        if not isinstance(tracking,dict):raise ValueError('FPGA has no tracking snapshot')
        seq=tracking['frame_id'];url=tracking.get('frame_url','')
        if raw is None and url!='/frame.png?seq='+str(seq):raise ValueError('FPGA image token is unavailable')
        png=png_gray(raw,tracking['width'],tracking['height'],1) if raw is not None else self.read(url,32768)
        if not png.startswith(b'\x89PNG\r\n\x1a\n'):raise ValueError('FPGA image is incomplete')
        tracking['frame_url']='/snapshot/frame.png?seq='+str(seq)
        tracking['frame_aligned']=True
        state.update(connected=True,link='板端 HTTP 同步',snapshot_transport='board_http')
        with self.lock:
            self.frames[str(seq)]=png
            while len(self.frames)>8:self.frames.pop(next(iter(self.frames)))
            self.latest=state;self.pixels=raw;self.updated=time.monotonic();self.error=''

    def snapshot(self):
        with self.lock:
            if self.latest is None:return None
            result=copy.deepcopy(self.latest);age=time.monotonic()-self.updated
            result.update(connected=age<10,snapshot_age_ms=round(age*1000),snapshot_error=self.error)
            return result

    def image(self,seq):
        with self.lock:return self.frames.get(str(seq))

    def packed(self,events=None):
        with self.lock:
            if self.latest is None or self.pixels is None:return None
            state=copy.deepcopy(self.latest);pixels=self.pixels;age=time.monotonic()-self.updated
            state.update(connected=age<10,snapshot_age_ms=round(age*1000),snapshot_error=self.error)
        if events is not None:state['events']=events[-8:]
        return encode_preview_packet(state,pixels)

    def run(self):
        while True:
            started=time.monotonic()
            try:self.poll_once()
            except Exception as error:
                with self.lock:self.error=str(error)
            # Follow real captures; a slow transfer never accumulates a queue.
            time.sleep(max(.02,.10-(time.monotonic()-started)))

ap = argparse.ArgumentParser()
ap.add_argument("--port", default=None, help="串口端口，例如 COM15（不给则不开串口）")
ap.add_argument("--udp", type=int, default=None, help="UDP 监听端口，例如 8080（不给则不开 UDP）")
ap.add_argument("--http", type=int, default=8080)
ap.add_argument("--bind", default="0.0.0.0", help="HTTP listen address")
ap.add_argument("--public-host", default="127.0.0.1", help="Address printed for browser access")
ap.add_argument("--board-url",default=None,help="Mirror the FPGA state and matched image, e.g. http://169.254.47.63")
ap.add_argument("--udp-pixel-encoding",choices=("uint8","legacy-offset128"),default="uint8",
                help="legacy-offset128 reverses the known +128 wrap in old firmware UDP images")
ap.add_argument("--preview-aspect",default="16:9",help="Physical camera region aspect, e.g. 16:9 or 1:1")
ap.add_argument("--out", type=Path, default=Path("out/live"))
a = ap.parse_args()
try:
    aspect_w,aspect_h=(int(x) for x in a.preview_aspect.split(':'))
    if aspect_w<=0 or aspect_h<=0:raise ValueError()
except ValueError:ap.error('--preview-aspect requires positive WIDTH:HEIGHT')
if a.port is None and a.udp is None and a.board_url is None:
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
track_parser = BoardTrackParser()
board_mirror=BoardHTTPMirror(a.board_url) if a.board_url else None

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

def decode_udp_pixels(buf,encoding):
    # The legacy firmware encodes (uint8_t)((int)raw_int8 + 128).
    # This is a reversible high-bit flip, not missing pixels or a denoise job.
    return bytes(value ^ 0x80 for value in buf) if encoding=="legacy-offset128" else bytes(buf)

def png_preview(buf,w,h,encoding,aspect=(16,9),width=384):
    pixels=decode_udp_pixels(buf,encoding)
    if len(pixels)!=w*h:raise ValueError('Incomplete preview frame')
    height=max(1,round(width*aspect[1]/aspect[0]))
    # Restore physical aspect; this only enlarges the original sampled pixels.
    resampled=bytes(pixels[min(h-1,y*h//height)*w+min(w-1,x*w//width)]
                    for y in range(height) for x in range(width))
    return png_gray(resampled,width,height,1)

THUMB_DIR = a.out / "thumbs"
THUMB_DIR.mkdir(parents=True, exist_ok=True)

# ---------------- UDP 事件/缩略图 ----------------
MAGIC = b"MT"
KIND = {0: "NORMAL", 1: "INTRUDE", 2: "TREND", 3: "PERSON", 4: "LOWPWR"}
PKT_EVENT, PKT_HEARTBEAT, PKT_THUMB = 1, 2, 3
LIVE_ID = 0xFFFF0001   # 固件 500 ms 推送的实时画面（不进事件列表）
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
    data = png_preview(buf[:THUMB_W * THUMB_H], THUMB_W, THUMB_H, a.udp_pixel_encoding,(aspect_w,aspect_h))
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
        if eid == LIVE_ID and len(t["parts"]) == t["total"]:
            try:
                buf = b"".join(t["parts"][i] for i in range(1, t["total"] + 1))
            except KeyError:
                return
            if len(buf) >= THUMB_W * THUMB_H:
                frame_png[0] = png_preview(buf[:THUMB_W * THUMB_H], THUMB_W, THUMB_H, a.udp_pixel_encoding,(aspect_w,aspect_h))
                (THUMB_DIR / "live.png").write_bytes(frame_png[0])
                state["live_ts"] = time.time()
                state["last"] = time.time()
            thumbs.pop(eid, None)
            return
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
            if eid == LIVE_ID:          # 实时画面丢片很正常，不计入事件/统计
                if now - t["last"] > 3:
                    thumbs.pop(eid, None)
                continue
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
    snapshot = track_parser.feed(s)
    if snapshot is not None:
        with lock:
            state["tracking"] = snapshot
    elif "MMT_BOOT" in s or "MMT_LIVE_BOOT" in s:
        with lock:
            state.pop("tracking", None)
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
        obs = re.search(r"\bobs=(-?\d+)", s)
        if obs: state["obs"] = int(obs.group(1))
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
        sensors = re.search(r"\bsht=(-?\d+) rh=(\d+) body=(-?\d+)", s)
        if sensors:
            state.update(sht=int(sensors.group(1)), rh=int(sensors.group(2)), body=int(sensors.group(3)))
        if prev == 0 and state["lowpwr"] == 1:
            add_event("lowpwr_enter", dict(f=state["f"]))
        if prev == 1 and state["lowpwr"] == 0:
            add_event("lowpwr_exit", dict(f=state["f"]))
        return
    m = re.search(r"sht=(\d+) rh=(\d+) body=(\d+)", s)
    if m:
        state.update(sht=int(m.group(1)), rh=int(m.group(2)), body=int(m.group(3))); return
    m = re.search(r"MMT_THUMB t=\d+ f=\d+ alarm=\d+ p=-?\d+ ([0-9a-f]+)\s*$", s)
    if m:
        if len(m.group(1)) not in (48*27*2,48*48*2): return
        raw = bytes.fromhex(m.group(1))
        if len(raw) == 48*27: frame_png[0] = png_gray(raw, 48, 27, 4)
        elif len(raw) == 48*48: frame_png[0] = png_gray(raw, 48, 48, 4)
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
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        try:self.wfile.write(body)
        except (BrokenPipeError,ConnectionResetError):pass
    def do_GET(self):
        if self.path=='/api/preview':
            with lock:ev=copy.deepcopy(events[-8:])
            packet=board_mirror.packed(ev) if board_mirror else None
            self._send(packet or b'',PREVIEW_MIME,200 if packet else 404);return
        if self.path.startswith("/api/state"):
            with lock:
                ev = events[-60:]
                ser = state["series"][-240:]
            mirrored=board_mirror.snapshot() if board_mirror else None
            if mirrored is not None:
                mirrored.update(events=ev,udp_events=stats['udp_events'],udp_heartbeats=stats['udp_heartbeats'])
                self._send(json.dumps(mirrored,ensure_ascii=False).encode());return
            body = json.dumps(dict(
                f=state["f"], p=state["p"], person=state["person"], motion=state["motion"],
                area=state["area"], ir=state["ir"], alarm=state["alarm"], lowpwr=state["lowpwr"],
                paused=state["paused"], camfps=state["camfps"], inf_hz=state["inf_hz"],
                sht=state["sht"], rh=state["rh"], body=state["body"], nt=state["nt"], obs=state["obs"],
                nd=state["nd"], last=state["last"], ts=state["ts"], link=state["link"],
                frames=stats["frames"], alarm_starts=stats["alarm_starts"],
                udp_events=stats["udp_events"], udp_heartbeats=stats["udp_heartbeats"],
                thumb_incomplete=stats["thumb_incomplete"],
                events=ev, series=ser, live_ts=state.get("live_ts", 0),
                tracking=state.get("tracking")), ensure_ascii=False).encode()
            self._send(body); return
        if self.path.startswith('/snapshot/frame.png?'):
            seq=urllib.parse.parse_qs(urllib.parse.urlsplit(self.path).query).get('seq',[''])[0]
            png=board_mirror.image(seq) if board_mirror else None
            self._send(png or b'', 'image/png',200 if png else 404);return
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
if board_mirror:
    threading.Thread(target=board_mirror.run,daemon=True).start()
threading.Thread(target=finalize_stale_thumbs, daemon=True).start()

state["link"] = ("串口+UDP" if (a.port and a.udp) else ("串口" if a.port else "UDP"))
state["ts"] = time.time()
print("HTTP http://%s:%d/  串口 %s  UDP %s  事件日志 %s"
      % (a.public_host, a.http, a.port or "-", a.udp or "-", a.out / "events.jsonl"), flush=True)
ThreadingHTTPServer((a.bind, a.http), H).serve_forever()
