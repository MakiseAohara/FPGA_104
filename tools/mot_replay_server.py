"""Offline tracker replay, isolated from COM15 and the running board monitor."""
import argparse,json,threading,time,urllib.parse
from http.server import BaseHTTPRequestHandler,ThreadingHTTPServer
from pathlib import Path

ROOT=Path(__file__).absolute().parents[1]
DATA=ROOT/'evidence/mot_web_20261104'
ap=argparse.ArgumentParser()
ap.add_argument('--http',type=int,default=8092)
ap.add_argument('--bind',default='0.0.0.0')
a=ap.parse_args()
scenarios=json.loads((DATA/'replays/index.json').read_text(encoding='utf8'))
frames={s['id']:json.loads((DATA/'replays'/s['id']/'frames.json').read_text(encoding='utf8')) for s in scenarios}
metrics=json.loads((DATA/'metrics.json').read_text(encoding='utf8'))
lock=threading.Lock();current=scenarios[0]['id'];cursor=0;playing=True;fps=5.;anchor=time.monotonic()

def position():
    global cursor,anchor
    now=time.monotonic()
    if playing:
        steps=int((now-anchor)*fps)
        if steps:cursor=(cursor+steps)%len(frames[current]);anchor+=steps/fps
    return cursor

class Handler(BaseHTTPRequestHandler):
    def log_message(self,*args):pass
    def send(self,data,kind='application/json; charset=utf-8',code=200):
        self.send_response(code);self.send_header('Content-Type',kind);self.send_header('Content-Length',str(len(data)));self.send_header('Cache-Control','no-store');self.end_headers()
        try:self.wfile.write(data)
        except (BrokenPipeError,ConnectionResetError):pass
    def json(self,value,code=200):self.send(json.dumps(value,ensure_ascii=False).encode(),code=code)
    def do_GET(self):
        url=urllib.parse.urlparse(self.path)
        if url.path=='/api/state':
            with lock:
                i=position();sample=frames[current][i];tracking=sample['tracking']
                state=dict(f=tracking['frame_id'],p=None,person=any(t['visible'] and t['supported'] for t in tracking['tracks']),motion=0,area=0,body=None,connected=True,link='离线回放',tracking=tracking,
                    replay=dict(enabled=True,scenario=current,scenarios=scenarios,index=i,total=len(frames[current]),playing=playing,fps=fps),evaluation=sample['evaluation'])
            self.json(state);return
        if url.path=='/api/metrics':self.json(metrics);return
        if url.path=='/replay/frame.png':
            q=urllib.parse.parse_qs(url.query)
            try:
                scene=q['scenario'][0];index=int(q['seq'][0]);assert scene in frames and 0<=index<len(frames[scene])
                self.send((DATA/'replays'/scene/f'{index}.png').read_bytes(),'image/png');return
            except (KeyError,ValueError,AssertionError):self.json({'error':'Unknown replay frame'},404);return
        if url.path in ('/','/page.html'):self.send((ROOT/'tools/page.html').read_bytes(),'text/html; charset=utf-8');return
        self.json({'error':'Not found'},404)
    def do_POST(self):
        global current,cursor,playing,fps,anchor
        if self.path!='/api/replay':self.json({'error':'Not found'},404);return
        try:
            length=int(self.headers.get('Content-Length','0'));assert 0<length<2048
            change=json.loads(self.rfile.read(length))
            with lock:
                position()
                if 'scenario' in change:
                    assert change['scenario'] in frames;current=change['scenario'];cursor=0
                if 'index' in change:cursor=max(0,min(len(frames[current])-1,int(change['index'])))
                if 'playing' in change:playing=bool(change['playing'])
                if 'fps' in change:fps=max(.1,min(15.,float(change['fps'])))
                anchor=time.monotonic()
            self.json({'ok':True})
        except (ValueError,AssertionError,TypeError):self.json({'error':'Invalid replay controls'},400)

print(f'Offline replay http://127.0.0.1:{a.http}/',flush=True)
ThreadingHTTPServer((a.bind,a.http),Handler).serve_forever()
