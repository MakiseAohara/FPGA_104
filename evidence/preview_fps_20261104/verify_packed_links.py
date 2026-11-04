"""Verify deployed PC/FPGA page identity and lossless image/track envelopes."""
import hashlib,json,sys,time,urllib.request
from pathlib import Path
HERE=Path(__file__).absolute().parent;ROOT=HERE.parents[1]
sys.path.insert(0,str(ROOT/'tools'))
from preview_protocol import decode_preview_packet
op=urllib.request.build_opener(urllib.request.ProxyHandler({}))
result={'passed':False,'manual_picture_confirmation':False,'samples':[],'checks':[]}
page=(ROOT/'tools/page.html').read_bytes()
for name,base in [('pc','http://169.254.47.62:8090'),('board','http://169.254.47.63')]:
    with op.open(base+'/',timeout=8) as response:assert response.read()==page
    result['checks'].append(name+': same shared HTML '+hashlib.sha256(page).hexdigest())
    ids=[]
    for index in range(4):
        for attempt in range(10):
            try:
                start=time.monotonic()
                with op.open(base+'/api/preview',timeout=8) as response:packet=response.read()
                elapsed=(time.monotonic()-start)*1000
                state,pixels=decode_preview_packet(packet);k=state['tracking']
                assert k['frame_aligned'] and k['width']==96 and k['height']==96 and len(pixels)==9216
                assert k['aspect_width']==1920 and k['aspect_height']==1080 and k['capacity']==2
                assert k['people_count']==k['metrics']['observed'] and 0<=k['people_count']<=2
                ids.append(k['frame_id'])
                result['samples'].append(dict(endpoint=name,frame_id=k['frame_id'],timestamp_ms=k['timestamp_ms'],sample_ms=k['sample_ms'],people_count=k['people_count'],packet_bytes=len(packet),transfer_ms=round(elapsed,2),age_ms=state.get('snapshot_age_ms'),attempt=attempt+1))
                (HERE/(name+'_live_preview.bin')).write_bytes(packet)
                (HERE/(name+'_live_preview.json')).write_text(json.dumps(state,ensure_ascii=False,indent=2),encoding='utf8')
                break
            except Exception:
                if attempt==9:raise
                time.sleep(.3)
        time.sleep(.25)
    result['checks'].append(name+': four valid lossless state/image pairs; unique captures '+str(len(set(ids))))
result['passed']=True
(HERE/'packed_live_links.json').write_text(json.dumps(result,ensure_ascii=False,indent=2),encoding='utf8')
print(json.dumps(result,ensure_ascii=False))
