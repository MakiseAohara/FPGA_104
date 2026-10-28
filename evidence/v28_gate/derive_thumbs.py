"""Decode complete MMT_THUMB lines; preserve received order and exact gray bytes."""
import argparse
import csv
import hashlib
import json
from pathlib import Path
import re
from PIL import Image,ImageDraw,ImageFont

THUMB=re.compile(r'^MMT_THUMB t=(\d+) f=(\d+) alarm=([01]) p=(-?\d+) ([0-9a-fA-F]{4608})$')
KV=re.compile(r'\b([A-Za-z_][A-Za-z0-9_]*)=([^\s]+)')
IMG=re.compile(r'^MMT_IMG\s+(\d{1,2})\s+([0-9a-fA-F]{192})\s*$')



def _gray(pixels):
    """MMT_IMG/MMT_THUMB bytes already are uint8 grayscale pixels."""
    return bytes(pixels)

def decode(root):
    root=Path(root);destination=root/'thumbs';destination.mkdir(exist_ok=True)
    lines=(root/'log_v28_gate.log').read_bytes().decode('utf-8',errors='replace').split('\n')
    if lines[-1]=='':lines.pop()
    else:lines.pop()  # A live preview never treats an unfinished log write as a line.
    rows=[];invalid=[];used={};session=0;active=False;dec={};full={};group=None;partial_thumbs=[]
    for number,line in enumerate(lines,1):
        if '\t' not in line:continue
        wall,body=line.split('\t',1);body=body.strip('\r')
        if body.startswith(('### PARTIAL_LINE_HEX ','### FINAL_PARTIAL_LINE_HEX ','### PRE_CAPTURE_PENDING_HEX ')):
            pending=bytes.fromhex(body.split(' ',2)[2])
            if b'MMT_THUMB ' in pending:partial_thumbs.append(dict(line=number,bytes=len(pending)))
        if body.startswith(('### RECONNECT_TRY','### GAP ')):group=None
        fields=dict(KV.findall(body))
        if body.startswith('MMT_LIVE_BOOT v28 '):session+=1;active=True;group=None
        if not active:continue
        if body.startswith('MMT_DEC '):dec[(session,int(fields['f']))]=fields
        elif body.startswith('MMT_IMGSTAT '):group={'f':int(fields['f']),'rows':{}}
        elif body.startswith('MMT_IMG ') and group is not None:
            match=IMG.fullmatch(body)
            if match and 0<=int(match[1])<96:
                group['rows'][int(match[1])]=bytes.fromhex(match[2])
                if len(group['rows'])==96:
                    full[(session,group['f'])]=b''.join(group['rows'][i] for i in range(96));group=None
        elif body.startswith('MMT_THUMB '):
            match=THUMB.fullmatch(body)
            if not match:invalid.append(dict(line=number,reason='invalid header or not exactly 2304 hex bytes'));continue
            t,f,alarm,p=map(int,match.group(1,2,3,4));pixels=bytes.fromhex(match[5])
            name=f'thumb_{t}_a{alarm}_p{p}.png'
            used[name]=used.get(name,0)+1
            if used[name]>1:name=name[:-4]+f'_dup{used[name]}.png'
            image=Image.frombytes('L',(48,48),_gray(pixels)).resize((192,192),Image.Resampling.NEAREST)
            image.save(destination/name)
            decision=dec.get((session,f))
            dec_status='missing'
            if decision is not None:
                dec_status='matched' if int(decision['t'])==t and int(decision['alarm_req'])==alarm else 'mismatch'
            matched=(session,f) in full
            if matched:
                original=full[(session,f)]
                expected=bytes(sum(original[(2*y+dy)*96+2*x+dx] for dy,dx in [(0,0),(0,1),(1,0),(1,1)])//4 for y in range(48) for x in range(48))
                assert pixels==expected,'Thumb differs from same-frame MMT_IMG 2x2 averages'
            rows.append(dict(device_ms=t,f=f,alarm=alarm,p=p,session=session,wall=wall,file='thumbs/'+name,
                             source_line=number,gray48_sha256=hashlib.sha256(pixels).hexdigest(),matched_full_image=matched,dec_status=dec_status))
    with (root/'thumbs.csv').open('w',encoding='utf-8',newline='') as stream:
        writer=csv.DictWriter(stream,fieldnames=['device_ms','f','alarm','p','session','wall','file','source_line','gray48_sha256','matched_full_image','dec_status'])
        writer.writeheader();writer.writerows(rows)
    font=ImageFont.load_default(size=14)
    pages=[]
    for first in range(0,len(rows),60):
        chunk=rows[first:first+60];page=first//60+1
        sheet=Image.new('RGB',(2120,1450),'white');draw=ImageDraw.Draw(sheet)
        draw.text((12,10),f'v28 | page {page:02} | {len(chunk)} complete thumbnails',fill='black',font=font)
        for index,item in enumerate(chunk):
            x=(index%10)*212;y=(index//10)*235+40
            with Image.open(root/item['file']) as thumb:sheet.paste(thumb,(x+10,y))
            draw.text((x+10,y+196),f"ms={item['device_ms']}",fill='black',font=font)
            draw.text((x+10,y+214),f"alarm={item['alarm']} p={item['p']}",fill='black',font=font)
        name=f'thumbs_sheet_{page:02}.png';sheet.save(root/name);pages.append(name)
    result=dict(thumbnail_lines=len(rows),invalid_lines=invalid,pages=pages,
                archived_partial_thumbnail_fragments=partial_thumbs,
                duplicate_filenames=sum(count-1 for count in used.values()),
                matched_96x96_averages=sum(row['matched_full_image'] for row in rows),
                missing_dec=sum(row['dec_status']=='missing' for row in rows),mismatched_dec=sum(row['dec_status']=='mismatch' for row in rows),
                first_device_ms=rows[0]['device_ms'] if rows else None,last_device_ms=rows[-1]['device_ms'] if rows else None,
                encoding='48x48 uint8 gray, floor 2x2 mean; nearest-neighbor enlarged to 192x192',
                truth_source='images for Claude; no presence labels inferred')
    (root/'thumbnail_counts.json').write_text(json.dumps(result,indent=2)+'\n',encoding='utf-8',newline='\n')
    print(json.dumps(result));return result


if __name__=='__main__':
    parser=argparse.ArgumentParser();parser.add_argument('--evidence',type=Path,required=True)
    decode(parser.parse_args().evidence)
