"""Independent byte / DEC / AI / image / manual-event consistency check."""
import argparse
import csv
import hashlib
import json
from pathlib import Path
import re
from PIL import Image


def rows(path):
    with path.open(encoding='utf-8-sig', newline='') as stream:
        return list(csv.DictReader(stream))


def verify(root):
    raw = (root/'uart_bytes.bin').read_bytes()
    bodies = [line.split('\t',1)[1] for line in (root/'log_v27_gate.log').read_bytes().decode('utf-8').split('\n') if '\t' in line]
    cursor = 0
    serial = []
    for body in bodies:
        if body.startswith(('### PARTIAL_LINE_HEX ', '### FINAL_PARTIAL_LINE_HEX ')):
            partial = bytes.fromhex(body.split(' ',2)[2])
            assert raw[cursor:cursor+len(partial)] == partial, 'Partial UART bytes differ'
            cursor += len(partial)
        elif not body.startswith('###'):
            end = raw.index(b'\n', cursor)
            assert raw[cursor:end].strip(b'\r').decode('ascii',errors='replace') == body.strip('\r'), 'UART line differs'
            serial.append(body.strip('\r'))
            cursor = end+1
    assert cursor == len(raw), 'Unaccounted UART bytes'
    kv = re.compile(r'\b([A-Za-z_][A-Za-z0-9_]*)=([^\s]+)')
    decisions = [dict(kv.findall(line)) for line in serial if line.startswith('MMT_DEC ')]
    ticks = rows(root/'ticks.csv')
    assert len(decisions) == len(ticks)
    for decision,tick in zip(decisions,ticks):
        for source,target in [('t','device_ms'),('motion','motion'),('area','area'),('person','person'),('alarm_req','alarm')]:
            assert decision.get(source,'') == tick[target], (source,tick['device_ms'])
    ai = rows(root/'ai_samples.csv')
    assert len(ai) == sum(line.startswith('MMT_AI ') for line in serial)
    complete, group = [], None
    for line in serial:
        if line.startswith('MMT_IMGSTAT '):
            group = dict(f=dict(kv.findall(line))['f'],pixels={})
        elif line.startswith('MMT_IMG ') and group is not None:
            match = re.fullmatch(r'MMT_IMG\s+(\d{1,2})\s+([0-9a-fA-F]{192})\s*',line)
            if match and 0<=int(match[1])<96:
                group['pixels'][int(match[1])] = bytes.fromhex(match[2])
                if len(group['pixels'])==96:
                    complete.append((group['f'],b''.join(group['pixels'][i] for i in range(96))))
                    group = None
    frames = rows(root/'frames.csv')
    assert len(frames)==len(complete)
    for frame,(f,pixels) in zip(frames,complete):
        assert frame['f']==f
        with Image.open(root/frame['file']) as image:
            assert image.size==(96,96) and image.mode=='L' and image.tobytes()==pixels
    manual = rows(root/'manual_events_raw.csv')
    mapped = rows(root/'manual_timetable.csv')
    for field in ['event','wall','elapsed_s','device_ms_latest','source']:
        assert [row[field] for row in manual] == [row[field] for row in mapped], field
    ir = rows(root/'ir_observation.csv')
    assert len(ir)==len(ticks)
    assert [row['irhot'] for row in ir] == [row.get('irhot','') for row in decisions]
    result = dict(serial_payload_matches_received_bytes=True,dec_rows=len(ticks),
                  actual_ai_rows=len(ai),exact_pixel_frames=len(frames),manual_rows_preserved=len(manual),
                  irhot_rows_preserved=len(ir),raw_log_sha256=hashlib.sha256((root/'log_v27_gate.log').read_bytes()).hexdigest())
    (root/'verification.json').write_text(json.dumps(result,indent=2)+'\n', encoding='utf-8')
    return result


if __name__=='__main__':
    parser=argparse.ArgumentParser()
    parser.add_argument('--evidence',type=Path,required=True)
    print(json.dumps(verify(parser.parse_args().evidence)))
