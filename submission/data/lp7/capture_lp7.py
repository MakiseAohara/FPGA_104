"""capture_lp7.py — 低功耗 7 分钟实测（A 空场 240s / B 有人 60s / C 空场 120s）

段间用 winsound 响提示音（1 声 = 下一段开始）。
产物（默认 out/lp7）：serial.log、manifest.json
用法：py -3 out\lp7\capture_lp7.py [--port COM15] [--out out\lp7] [--scale 1.0]
"""
import argparse, json, sys, time
from pathlib import Path

try:
    import winsound
except Exception:
    winsound = None
import serial

SEGS = [('A', 240, '空场景，无人，不要有热源'),
        ('B', 60,  '有人进入并走动'),
        ('C', 120, '人离开，空场景')]

ap = argparse.ArgumentParser()
ap.add_argument('--port', default='COM15')
ap.add_argument('--out', type=Path, default=Path('out/lp7'))
ap.add_argument('--scale', type=float, default=1.0)
a = ap.parse_args()
a.out.mkdir(parents=True, exist_ok=True)

def beep(n=1):
    if not winsound:
        return
    for _ in range(n):
        winsound.Beep(1200, 350)
        time.sleep(0.15)

log = (a.out / 'serial.log').open('w', encoding='utf-8', newline='\n')
buf = bytearray()
manifest = dict(port=a.port, start=time.strftime('%Y-%m-%dT%H:%M:%S'), segments=[])

with serial.Serial(a.port, 115200, timeout=0.05) as port:
    port.reset_input_buffer()
    for name, secs, hint in SEGS:
        beep(1)                                  # 1 声 = 本段开始
        t0 = time.monotonic()
        wall0 = time.strftime('%Y-%m-%dT%H:%M:%S')
        print(f'[{time.strftime("%H:%M:%S")}] {name} 段开始 {int(secs*a.scale)}s — {hint}', flush=True)
        n = 0
        while time.monotonic() - t0 < secs * a.scale:
            chunk = port.read(max(1, port.in_waiting))
            if not chunk:
                continue
            buf.extend(chunk)
            while b'\n' in buf:
                line, tail = buf.split(b'\n', 1); buf[:] = tail
                text = line.decode('ascii', errors='replace').rstrip('\r')
                log.write(f'{name} {time.monotonic()-t0:8.3f} {text}\n')
                n += 1
        log.flush()
        manifest['segments'].append(dict(name=name, hint=hint, dur_s=round(secs * a.scale, 1),
                                         start=wall0, end=time.strftime('%Y-%m-%dT%H:%M:%S'),
                                         lines=n))
    beep(2)                                      # 2 声 = 全部结束
log.close()
manifest['end'] = time.strftime('%Y-%m-%dT%H:%M:%S')
(a.out / 'manifest.json').write_text(json.dumps(manifest, indent=2, ensure_ascii=False) + '\n', encoding='utf-8')
print('DONE', json.dumps(manifest['segments'], ensure_ascii=False))
