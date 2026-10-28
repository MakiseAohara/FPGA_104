"""Independent received-byte, decision, inference and thumbnail checks."""
import argparse
import csv
import hashlib
import json
from pathlib import Path
import re
from PIL import Image

KV=re.compile(r'\b([A-Za-z_][A-Za-z0-9_]*)=([^\s]+)')
THUMB=re.compile(r'^MMT_THUMB t=(\d+) f=(\d+) alarm=([01]) p=(-?\d+) ([0-9a-fA-F]{4608})$')


def csv_rows(path):
    with path.open(encoding='utf-8-sig',newline='') as stream:return list(csv.DictReader(stream))


def verify(root):
    root=Path(root);raw=(root/'uart_bytes.bin').read_bytes()
    bodies=[line.split('\t',1)[1] for line in (root/'log_v29_gate.log').read_bytes().decode('utf-8').split('\n') if '\t' in line]
    cursor=0;serial=[]
    for body in bodies:
        if body.startswith(('### PARTIAL_LINE_HEX ','### FINAL_PARTIAL_LINE_HEX ','### PRE_CAPTURE_PENDING_HEX ')):
            partial=bytes.fromhex(body.split(' ',2)[2]);assert raw[cursor:cursor+len(partial)]==partial
            cursor+=len(partial)
        elif not body.startswith('###'):
            end=raw.index(b'\n',cursor)
            assert raw[cursor:end].strip(b'\r').decode('ascii',errors='replace')==body.strip('\r'),'UART payload changed'
            serial.append(body.strip('\r'));cursor=end+1
    assert cursor==len(raw),'Unaccounted UART bytes'
    serial=serial[next(i for i,body in enumerate(serial) if body.startswith('MMT_LIVE_BOOT v29 ')):]
    decisions=[fields for body in serial if body.startswith('MMT_DEC ') and (fields:=dict(KV.findall(body))).get('t','').isdigit()]
    ticks=csv_rows(root/'ticks.csv');assert len(ticks)==len(decisions)
    for tick,decision in zip(ticks,decisions):
        for source,dest in [('t','device_ms'),('motion','motion'),('area','area'),('person','person'),('alarm_req','alarm'),('irhot','irhot'),('ir_cnt','ir_cnt')]:
            assert tick[dest]==decision.get(source,''),(dest,tick['device_ms'])
    ai=csv_rows(root/'ai_samples.csv')
    assert len(ai)==sum(body.startswith('MMT_AI ') for body in serial)
    thumbs=[THUMB.fullmatch(body) for body in serial if body.startswith('MMT_THUMB ')]
    complete=[match for match in thumbs if match]
    index=csv_rows(root/'thumbs.csv');assert len(index)==len(complete)
    for row,match in zip(index,complete):
        assert [row[key] for key in ['device_ms','f','alarm','p']]==list(match.group(1,2,3,4))
        pixels=bytes.fromhex(match[5]);assert hashlib.sha256(pixels).hexdigest()==row['gray48_sha256']
        expected=Image.frombytes('L',(48,48),pixels).resize((192,192),Image.Resampling.NEAREST)
        with Image.open(root/row['file']) as image:
            assert image.size==(192,192) and image.mode=='L' and image.tobytes()==expected.tobytes()
    sheets=list(root.glob('thumbs_sheet_*.png'))
    assert len(sheets)==(len(index)+59)//60
    # Full images use the same unmodified uint8 byte rule as thumbnails.
    groups={};session=0;current=None;parts={}
    for body in bodies:
        body=body.strip('\r')
        if body.startswith(('### GAP ','### RECONNECT_TRY','### CAPTURE_END','### RESUME_CAPTURE')):
            current=None;parts={}
        if body.startswith('MMT_LIVE_BOOT v29 '):session+=1;current=None;parts={}
        if body.startswith('MMT_IMGSTAT '):
            fields=dict(KV.findall(body));current=(session,int(fields['f']));parts={}
        match=re.fullmatch(r'MMT_IMG\s+(\d{1,2})\s+([0-9a-fA-F]{192})',body)
        if match and current is not None:
            y=int(match[1])
            if y!=len(parts) or y>=96:
                current=None;parts={};continue
            parts[y]=bytes.fromhex(match[2])
            if len(parts)==96:groups[current]=b''.join(parts.values());current=None;parts={}
    full=csv_rows(root/'frames.csv')
    for row in full:
        with Image.open(root/row['file']) as image:
            assert image.mode=='L' and image.size==(96,96)
            assert image.tobytes()==groups[(int(row['session']),int(row['f']))]
    assert not (root/'manual_events_raw.csv').exists(),'v29 requests no fabricated action labels'
    result=dict(serial_payload_matches_received_bytes=True,dec_rows=len(ticks),actual_ai_rows=len(ai),
                exact_thumbnail_pixels=len(index),exact_full_image_pixels=len(full),malformed_thumbnail_lines=len(thumbs)-len(complete),
                sheet_pages=len(sheets),raw_log_sha256=hashlib.sha256((root/'log_v29_gate.log').read_bytes()).hexdigest())
    (root/'verification.json').write_text(json.dumps(result,indent=2)+'\n',encoding='utf-8',newline='\n')
    print(json.dumps(result));return result


if __name__=='__main__':
    parser=argparse.ArgumentParser();parser.add_argument('--evidence',type=Path,required=True)
    verify(parser.parse_args().evidence)
