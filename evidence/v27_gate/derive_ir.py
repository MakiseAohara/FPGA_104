"""List received irhot/body10 values by actual human input; no detector verdict."""
import bisect
from collections import Counter
import csv
import json
from pathlib import Path
import re

KV = re.compile(r'\b([A-Za-z_][A-Za-z0-9_]*)=([^\s]+)')


def build(evidence):
    evidence = Path(evidence)
    with (evidence/'manual_events_raw.csv').open(encoding='utf-8-sig', newline='') as stream:
        manual = list(csv.DictReader(stream))
    phases = sorted((row['wall'], row['event']) for row in manual
                    if row['event'] in ('ENTER', 'LEAVE', 'EMPTY_CONFIRMED'))
    phase_walls = [row[0] for row in phases]
    rows, body_by_frame = [], {}
    session = 1
    last_ms = None
    for line in (evidence/'log_v27_gate.log').read_bytes().decode('utf-8').split('\n'):
        if '\t' not in line:
            continue
        wall, text = line.split('\t', 1)
        values = dict(KV.findall(text))
        if text.startswith('MMT_LIVE_BOOT'):
            session += 1
        if text.startswith('MMT_LP ') and 'f' in values:
            body_by_frame[(session, values['f'])] = values.get('body', '')
        elif text.startswith('MMT_DEC ') and 't' in values:
            device_ms = int(values['t'])
            if last_ms is not None and device_ms < last_ms:
                session += 1
            last_ms = device_ms
            index = bisect.bisect_right(phase_walls, wall) - 1
            prior = phases[index] if index >= 0 else ('', '')
            phase = 'person' if prior[1] == 'ENTER' else 'empty' if prior[1] else 'unlabelled'
            rows.append(dict(session=session, device_ms=device_ms, wall=wall,
                             irhot=values.get('irhot', ''), body10=body_by_frame.get((session, values.get('f')), ''),
                             human_phase=phase, human_phase_wall=prior[0], human_phase_event=prior[1]))
    with (evidence/'ir_observation.csv').open('w', encoding='utf-8', newline='') as stream:
        writer = csv.DictWriter(stream, fieldnames=['session','device_ms','wall','irhot','body10','human_phase','human_phase_wall','human_phase_event'])
        writer.writeheader()
        writer.writerows(rows)
    counts = {phase: dict(Counter(r['irhot'] for r in rows if r['human_phase'] == phase))
              for phase in ('unlabelled', 'empty', 'person')}
    values = {r['irhot'] for r in rows if r['irhot'] != ''}
    result = dict(dec_rows=len(rows), irhot_by_operator_phase=counts,
                  constant_irhot=next(iter(values)) if len(values) == 1 else None,
                  phase_source='actual ENTER/LEAVE/EMPTY_CONFIRMED inputs only; no inferred initial empty scene',
                  body_source='same-session same-frame MMT_LP.body; missing values left blank',
                  video_files=[p.name for p in evidence.glob('*.mp4')])
    (evidence/'ir_observation.json').write_text(json.dumps(result, ensure_ascii=False, indent=2)+'\n', encoding='utf-8')
    summary = evidence/'summary.md'
    with summary.open('a', encoding='utf-8', newline='\n') as stream:
        stream.write('\n## 红外串口观察\n\n')
        stream.write('ir_observation.csv 保留每条 DEC 的 irhot 及同帧 body10。阶段只沿用实际 ENTER / LEAVE / EMPTY_CONFIRMED 按键，首次按键之前标为 unlabelled。\n\n')
        stream.write('| 实际按键阶段 | irhot 计数 |\n|---|---|\n')
        for phase, values_count in counts.items():
            stream.write(f'| {phase} | `{json.dumps(values_count)}` |\n')
        if result['constant_irhot'] is not None:
            stream.write(f"\nirhot 在有值的 DEC 中全程恒为 {result['constant_irhot']}；只记录现象，不自行调参或修改 RTL。\n")
        stream.write('\n手机视频：'+('、'.join(result['video_files']) if result['video_files'] else '未提供文件；没有热力图或手靠近/拿开片段的视频观察结论。')+'\n')
    return result


if __name__ == '__main__':
    import argparse
    parser = argparse.ArgumentParser()
    parser.add_argument('--evidence', type=Path, required=True)
    print(json.dumps(build(parser.parse_args().evidence), ensure_ascii=False))
