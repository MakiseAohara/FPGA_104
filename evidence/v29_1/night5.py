"""night5.py — NIGHT 固件 5 分钟采集（独占 COM15）。"""
import json, re, sys, time
from pathlib import Path
from PIL import Image

EFINITY = Path(r'D:\Efinity\2026.1')
sys.path.append(str(EFINITY / 'python311/Lib/site-packages'))
import serial

ROOT = Path(r'C:\Users\Makise Aohara\Documents\deepseek-harness\default-workspace\_v29work\FPGA_104-main')
OUT = ROOT / 'evidence/v29_1/night5'
FRAMES = OUT / 'frames'
THUMBS = OUT / 'thumbs'
for d in (OUT, FRAMES, THUMBS):
    d.mkdir(parents=True, exist_ok=True)

SECONDS = int(sys.argv[1]) if len(sys.argv) > 1 else 300
PORT = sys.argv[2] if len(sys.argv) > 2 else 'COM15'

def iso(ms):
    import datetime as dt
    return dt.datetime.fromtimestamp(ms / 1000, dt.timezone(dt.timedelta(hours=8))).isoformat(timespec='milliseconds')

start_ms = int(time.time() * 1000)
manifest = dict(firmware='tinyml_pdti8_v291_night.bin', crc32='B534DE8E', port=PORT,
                bitstream='v7_MERGE16.bit', duration_s=SECONDS,
                mean_sensor=31, mean_sensor_expected='80-130',
                started_local=iso(start_ms), started_ms=start_ms,
                ended_local=None, ended_ms=None, lines=0, frames=0, thumbs=0,
                boot=[], interrupted=False, chunks=[])
(OUT / 'manifest.json').write_text(json.dumps(manifest, ensure_ascii=False, indent=2), encoding='utf-8')

log = (OUT / 'serial.log').open('w', encoding='utf-8', newline='\n')
ser = serial.Serial(PORT, 115200, timeout=0.05)

buf = b''
cur_frame = 0
rows = {}
lines = 0
RE_IMGSTAT = re.compile(r'MMT_IMGSTAT f=(\d+)')
RE_IMG = re.compile(r'MMT_IMG (\d\d) ([0-9a-fA-F]{192})')
RE_THUMB = re.compile(r'MMT_THUMB t=(\d+) f=(\d+) alarm=(\d+) p=(-?\d+) ([0-9a-fA-F]+)')
RE_BOOT = re.compile(r'(MMT_LIVE_BOOT|MMT_WB_INIT|MMT_LOAD_CRC|MMT_CAM_PRESET)[^\r\n]*')

deadline = time.monotonic() + SECONDS
try:
    while time.monotonic() < deadline:
        chunk = ser.read(2048)
        if not chunk:
            continue
        buf += chunk
        while b'\n' in buf:
            raw, buf = buf.split(b'\n', 1)
            text = raw.decode('utf-8', 'replace').rstrip('\r')
            pc = int(time.time() * 1000)
            log.write('%d\t%s\n' % (pc, text))
            lines += 1
            if (lines % 10) == 0:
                log.flush()
            m = RE_IMGSTAT.search(text)
            if m:
                cur_frame = int(m.group(1)); rows = {}; continue
            m = RE_IMG.search(text)
            if m:
                y = int(m.group(1)); rows[y] = bytes.fromhex(m.group(2))
                if len(rows) == 96:
                    Image.frombytes('L', (96, 96), b''.join(rows[i] for i in range(96))).save(
                        FRAMES / ('img_%06d.png' % cur_frame))
                    manifest['frames'] += 1; rows = {}
                continue
            m = RE_THUMB.search(text)
            if m:
                t, f, alarm, p, hexs = m.groups()
                data = bytes.fromhex(hexs)
                if len(data) == 48 * 48:
                    Image.frombytes('L', (48, 48), data).save(THUMBS / ('thumb_%s_%06d.png' % (t, int(f))))
                    manifest['thumbs'] += 1
                continue
            m = RE_BOOT.search(text)
            if m and len(manifest['boot']) < 12:
                manifest['boot'].append(text)
finally:
    log.flush(); log.close()
    try: ser.close()
    except Exception: pass
    end_ms = int(time.time() * 1000)
    manifest['ended_ms'] = end_ms
    manifest['ended_local'] = iso(end_ms)
    manifest['lines'] = lines
    manifest['chunks'].append(dict(start=iso(start_ms), end=iso(end_ms),
                                   seconds=round((end_ms - start_ms) / 1000, 1), lines=lines))
    (OUT / 'manifest.json').write_text(json.dumps(manifest, ensure_ascii=False, indent=2), encoding='utf-8')
    print('DONE lines=%d frames=%d thumbs=%d' % (lines, manifest['frames'], manifest['thumbs']), flush=True)
