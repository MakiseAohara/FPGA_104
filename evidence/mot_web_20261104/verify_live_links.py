"""Automatic transport/UI contract checks; no person-presence claim."""
import hashlib,json,struct,time,urllib.request,zlib
from pathlib import Path
HERE=Path(__file__).absolute().parent
ROOT=HERE.parents[1]
op=urllib.request.build_opener(urllib.request.ProxyHandler({}))
def get(base,path):
    with op.open(base+path,timeout=8) as r:return r.read()
def png_check(data):
    assert data[:8]==b'\x89PNG\r\n\x1a\n'
    pos=8;compressed=b'';size=struct.unpack('>II',data[16:24])
    while pos<len(data):
        n=int.from_bytes(data[pos:pos+4],'big');kind=data[pos+4:pos+8];part=data[pos+8:pos+8+n]
        assert zlib.crc32(kind+part)==int.from_bytes(data[pos+8+n:pos+12+n],'big')
        if kind==b'IDAT':compressed+=part
        pos+=n+12
    assert len(zlib.decompress(compressed))==(size[0]+1)*size[1]
    return size
result={'manual_person_test':False,'checks':[],'samples':[]}
expected=(ROOT/'tools/page.html').read_bytes()
for name,base in [('pc','http://169.254.47.62:8090'),('board','http://169.254.47.63')]:
    page=get(base,'/');assert page==expected
    result['checks'].append(name+': shared HTML bytes match '+hashlib.sha256(page).hexdigest())
    for i in range(3):
        for attempt in range(4):
            try:
                state=json.loads(get(base,'/api/state'));k=state['tracking']
                assert k['frame_aligned'] and k['capacity']==2
                assert k['aspect_width']==1920 and k['aspect_height']==1080
                assert 0<=k['people_count']<=k['capacity']
                assert k['people_count']==k['metrics']['observed']
                png=get(base,k['frame_url']);size=png_check(png)
                assert size==(96,96)
                (HERE/f'{name}_live_state.json').write_text(json.dumps(state,ensure_ascii=False,indent=2),encoding='utf8')
                (HERE/f'{name}_live_frame.png').write_bytes(png)
                result['samples'].append(dict(endpoint=name,frame_id=k['frame_id'],people_count=k['people_count'],png_bytes=len(png),size=size,attempt=attempt+1))
                break
            except Exception:
                if attempt==3:raise
                time.sleep(.5)
    result['checks'].append(name+': three aligned state/PNG pairs, count, aspect and complete pixels passed')
result['passed']=True
(HERE/'live_links_verified.json').write_text(json.dumps(result,ensure_ascii=False,indent=2),encoding='utf8')
print(json.dumps(result,ensure_ascii=False))
