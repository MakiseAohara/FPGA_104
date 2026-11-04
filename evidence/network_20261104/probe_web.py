"""Record real PC/board HTTP responses without proxying through the PC server."""
import argparse, urllib.request, json, time, hashlib, struct, zlib
from pathlib import Path

ap=argparse.ArgumentParser()
ap.add_argument('--base',default='http://169.254.47.63')
ap.add_argument('--out',type=Path,required=True)
ap.add_argument('--rounds',type=int,default=2)
a=ap.parse_args();a.out.mkdir(exist_ok=True,parents=True)
op=urllib.request.build_opener(urllib.request.ProxyHandler({}))
expected=(Path(__file__).resolve().parents[2]/'tools/page.html').read_bytes()
results=[]
for attempt in range(a.rounds):
    for name,path in [('status','/api/state'),('page','/'),('frame','/frame.png?t='+str(time.time_ns()))]:
        t=time.monotonic();record={'round':attempt,'path':path,'url':a.base+path}
        try:
            with op.open(urllib.request.Request(a.base+path,headers={'Connection':'close'}),timeout=18) as r:
                b=r.read();record.update(status=r.status,bytes=len(b),sha256=hashlib.sha256(b).hexdigest())
            (a.out/f'{attempt}_{name}.bin').write_bytes(b)
            if name=='page':
                assert b==expected,'Page differs from current source'
            elif name=='status':
                state=json.loads(b);record['state']=state
                assert 'f' in state and 'body' in state
            else:
                assert b[:8]==b'\x89PNG\r\n\x1a\n'
                record['dimensions']=struct.unpack('!II',b[16:24])
                pos=8;data=b''
                while pos<len(b):
                    size=int.from_bytes(b[pos:pos+4],'big');chunk=b[pos+4:pos+8+size]
                    assert zlib.crc32(chunk)==int.from_bytes(b[pos+8+size:pos+12+size],'big')
                    if chunk[:4]==b'IDAT':data+=chunk[4:]
                    pos+=size+12
                zlib.decompress(data)
            record['passed']=True
        except Exception as e:record.update(passed=False,error=repr(e))
        record['seconds']=round(time.monotonic()-t,3)
        results.append(record)
        print(json.dumps(record,ensure_ascii=False),flush=True)
        (a.out/'result.json').write_text(json.dumps(results,ensure_ascii=False,indent=2),encoding='utf8')
raise SystemExit(0 if all(r['passed'] for r in results) else 1)
