"""sim_gate.py — 离线评估报警门控（现状 / B 面积上限 / C MOT确认航迹 / B+C）"""
import re, sys

def field(line, key, cast=int):
    m = re.search(key + r'=(-?\d+)', line)
    return cast(m.group(1)) if m else None

def load(path):
    """按帧号聚合：mmt_dec / 分数 / MOT 确认数"""
    frames = {}
    for line in open(path, encoding='utf-8', errors='replace'):
        if 'MMT_DEC' in line and 'f=' in line:
            f = field(line, r' f')
            if f is None: continue
            frames.setdefault(f, {})['dec'] = dict(
                alarm=field(line, 'alarm_req'), motion=field(line, 'motion'),
                area=field(line, 'area'), person=field(line, 'person'),
                ir=field(line, 'ir_cnt'))
        elif 'MMT_MOT' in line:
            f = field(line, r' f')
            if f is None: continue
            frames.setdefault(f, {})['conf'] = field(line, 'conf')
        elif 'MMT_AI' in line:
            f = field(line, r' f')
            if f is None: continue
            frames.setdefault(f, {})['p'] = field(line, r' p')
    return frames

def count(frames, area_max, need_mot):
    trig = tp = 0
    for f, rec in frames.items():
        d = rec.get('dec')
        if not d or d['motion'] is None: continue
        cand = d['motion'] == 1 and 200 <= (d['area'] or 0) <= area_max
        ir_ok = (d['ir'] or 0) >= 2
        mot_ok = (rec.get('conf') or 0) >= 1 if need_mot else True
        if cand and ir_ok and mot_ok:
            trig += 1
            if d['person'] == 1: tp += 1
    return trig, tp

for path in sys.argv[1:]:
    fr = load(path)
    name = path.replace('\\', '/').split('/')[-2] + '/' + path.replace('\\', '/').split('/')[-1]
    print('\n=== %s (%d 帧) ===' % (name, len(fr)))
    for label, amax, need in (('现状', 20000, False), ('B 面积<=4000', 4000, False),
                              ('C 需确认航迹', 20000, True), ('B+C', 4000, True)):
        trig, tp = count(fr, amax, need)
        print('  %-14s 触发 %4d 帧 (person=1: %3d, person=0: %3d)' % (label, trig, tp, trig - tp))
