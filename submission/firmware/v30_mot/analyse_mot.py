"""analyse_mot.py — 从串口日志统计 v30 MOT/预测表现。
用法: py -3 analyse_mot.py <serial.log> [--json out.json]
输出: 航迹数/ID 稳定性/速度/预测误差/预警提前量 等事实数字（不做结论）。
"""
import argparse, json, re, statistics as st
from collections import defaultdict

ap = argparse.ArgumentParser()
ap.add_argument('log')
ap.add_argument('--json', dest='js')
a = ap.parse_args()

trk = re.compile(r'MMT_TRK f=(\d+) id=(\d+) c=(-?\d+),(-?\d+) b=(-?\d+),(-?\d+),(-?\d+),(-?\d+) '
                 r'v16=(-?\d+),(-?\d+) dir=(\d+) hit=(\d+) miss=(\d+) conf=(\d+) pred=(-?\d+),(-?\d+) eta=(-?\d+)')
mot = re.compile(r'MMT_MOT f=(\d+) nd=(\d+) nt=(\d+) conf=(\d+) area=(\d+)(?: raw=(\d+))? pre=(\d+) pre_eta=(-?\d+)')
pre = re.compile(r'MMT_PREWARN f=(\d+) id=(\d+) eta=(-?\d+) ms=(\d+)')
lead = re.compile(r'MMT_PREDLEAD f=(\d+) lead_ms=(\d+) id=(\d+) eta=(-?\d+)')
alarm = re.compile(r'MMT_ALARM (start|end) ms=(\d+)')

ids = defaultdict(list)          # id -> [(f, cx, cy, px, py)]
mot_rows, pre_rows, lead_rows, alarms = [], [], [], []
conf_max = 0
for line in open(a.log, encoding='utf-8', errors='replace'):
    m = trk.search(line)
    if m:
        g = m.groups()
        ids[int(g[1])].append(dict(f=int(g[0]), cx=int(g[2]), cy=int(g[3]),
                                   vx=int(g[8]), vy=int(g[9]), dir=int(g[10]),
                                   hits=int(g[11]), miss=int(g[12]), conf=int(g[13]),
                                   px=int(g[14]), py=int(g[15]), eta=int(g[16])))
        continue
    m = mot.search(line)
    if m:
        g = m.groups()
        mot_rows.append(dict(f=int(g[0]), nd=int(g[1]), nt=int(g[2]), conf=int(g[3]), area=int(g[4]), pre=int(g[6]), pre_eta=int(g[7])))
        conf_max = max(conf_max, int(m.group(4)))
        continue
    m = pre.search(line)
    if m: pre_rows.append(dict(zip(['f','id','eta','ms'], map(int, m.groups())))); continue
    m = lead.search(line)
    if m: lead_rows.append(dict(zip(['f','lead_ms','id','eta'], map(int, m.groups())))); continue
    m = alarm.search(line)
    if m: alarms.append((m.group(1), int(m.group(2))))

def pred_err(t):
    """用同一目标下一帧的实际质心检验上一帧的预测（提前 2 帧 = 至少 1 帧的领先量）"""
    return max(abs(t['px'] - t['cx']), abs(t['py'] - t['cy']))

errs = [pred_err(t) for v in ids.values() for t in v if t['conf']]
vxs = [abs(t['vx']) / 16.0 for v in ids.values() for t in v if t['conf'] and t['vx']]
conf_tracks = {i: v for i, v in ids.items() if any(t['conf'] for t in v)}
conf_len = [len(v) for v in conf_tracks.values()]
dirs = defaultdict(int)
for v in conf_tracks.values():
    for t in v:
        dirs[t['dir']] += 1
res = {
    'confirmed_tracks': len(conf_tracks),
    'confirmed_track_len_median': st.median(conf_len) if conf_len else 0,
    'confirmed_track_len_max': max(conf_len, default=0),
    'dir_hist': dict(sorted(dirs.items())),
    'frames_with_mot': len(mot_rows),
    'tracks_total': len(ids),
    'track_len_median': st.median([len(v) for v in ids.values()]) if ids else 0,
    'track_len_max': max([len(v) for v in ids.values()], default=0),
    'confirmed_max': conf_max,
    'nonzero_track_frames': sum(1 for r in mot_rows if r['nt'] > 0),
    'prewarn_count': len(pre_rows),
    'lead_count': len(lead_rows),
    'lead_ms_median': st.median([r['lead_ms'] for r in lead_rows]) if lead_rows else None,
    'alarms': len(alarms),
    'pred_err_median_px': st.median(errs) if errs else None,
    'pred_err_p90_px': (sorted(errs)[int(len(errs)*0.9)] if errs else None),
    'speed_px_per_frame_median': round(st.median(vxs), 2) if vxs else None,
    'track_ids': sorted(ids.keys())[:20],
}
print(json.dumps(res, indent=2, ensure_ascii=False))
if a.js:
    open(a.js, 'w', encoding='utf-8').write(json.dumps(res, indent=2, ensure_ascii=False) + '\n')
