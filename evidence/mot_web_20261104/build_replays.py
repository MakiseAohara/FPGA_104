"""Run the C tracker over labelled synthetic scenes, then preserve snapshots.

The generated rectangles have exact synthetic ground truth. Recorded scenes,
when available, are explicitly separate and carry their real dump timestamps.
"""
import ctypes as C, itertools, json, math, struct, zlib
from pathlib import Path

HERE=Path(__file__).absolute().parent
OUT=HERE/'replays'
OUT.mkdir(exist_ok=True)

class Tracker:
    def __init__(self,name):
        self.lib=C.CDLL(str(HERE/(name+'.dll')))
        self.lib.step.argtypes=[C.c_char_p,C.c_int,C.c_int,C.c_uint32]
        self.lib.snapshot.argtypes=[C.c_void_p,C.c_int,C.c_int]
        self.buf=C.create_string_buffer(8192)
    def reset(self): self.lib.reset()
    def step(self,pixels,ai,ir,ms,index):
        self.lib.step(pixels,ai,ir,ms)
        n=self.lib.snapshot(self.buf,len(self.buf),index)
        if n<=0:raise RuntimeError('Snapshot overflow')
        return json.loads(self.buf.raw[:n])

def png_gray(pixels):
    def chunk(kind,data):
        return struct.pack('!I',len(data))+kind+data+struct.pack('!I',zlib.crc32(kind+data))
    rows=b''.join(b'\0'+pixels[y*96:(y+1)*96] for y in range(96))
    return b'\x89PNG\r\n\x1a\n'+chunk(b'IHDR',struct.pack('!IIBBBBB',96,96,8,0,0,0,0))+chunk(b'IDAT',zlib.compress(rows))+chunk(b'IEND',b'')

def synthetic(name):
    count=96;stamp=0;frames=[]
    for i in range(count):
        dt=[100,200,350,150][i%4] if name=='variable' else 200
        stamp+=dt;n=i-8;people=[]
        if n>=0:
            if name=='parallel': people=[(1,15+n*.28,25,True),(2,70-n*.18,66,True)]
            elif name=='crossing':
                people=[(1,11+min(n,55)*1.2,44,True),(2,80-min(n,55)*1.2,44,True)]
            elif name=='occlusion':people=[(1,12+min(n,75)*.7,46,not 26<=n<=28)]
            elif name=='stop_turn':
                x=12+n if n<25 else (37 if n<40 else max(12,37-(n-40)*.8))
                people=[(1,x,46,True)]
            elif name=='variable':people=[(1,min(77,12+8*(stamp-1600)/1000),46,True)]
        pixels=bytearray(40+(x*7+y*3)%7 for y in range(96) for x in range(96))
        truth=[]
        for ident,x,y,visible in people:
            x=max(6,min(89,round(x)));y=round(y)
            box=[x-5,y-13,x+5,y+13]
            truth.append(dict(id=ident,center=[x,y],bbox=box,visible=visible))
            if visible:
                for yy in range(box[1],box[3]+1):
                    for xx in range(box[0],box[2]+1):pixels[yy*96+xx]=155+ident*30+(xx+yy)%5
        if name=='lighting' and 24<=i<=26:
            pixels=bytearray(min(255,p+65) for p in pixels)
        frames.append(dict(timestamp_ms=stamp,pixels=bytes(pixels),truth=truth,ai=90 if people else -100,ir=0))
    return frames

SCENES=[('parallel','双人并行'),('crossing','双人交会'),('occlusion','短时遮挡'),('stop_turn','停止与折返'),('variable','不均匀采样'),('lighting','光照变化空场')]

def matching(tracks,truth):
    observed=[t for t in tracks if t['visible'] and t['supported']]
    expected=[g for g in truth if g['visible']]
    best=(-1,float('inf'),[])
    for size in range(min(len(observed),len(expected))+1):
        for ids in itertools.combinations(range(len(observed)),size):
            for js in itertools.permutations(range(len(expected)),size):
                pairs=[];cost=0
                for a,b in zip(ids,js):
                    d=math.dist(observed[a]['center'],expected[b]['center'])
                    if d>14:break
                    pairs.append((observed[a],expected[b]));cost+=d
                else:
                    if size>best[0] or size==best[0] and cost<best[1]:best=(size,cost,pairs)
    return best[2],len(observed),len(expected)

def future_truth(frames,index,ident,target):
    for j in range(index+1,len(frames)):
        if frames[j]['timestamp_ms']<target:continue
        a,b=frames[j-1],frames[j]
        ga=next((g for g in a['truth'] if g['id']==ident and g['visible']),None)
        gb=next((g for g in b['truth'] if g['id']==ident and g['visible']),None)
        if not ga or not gb:return None
        frac=(target-a['timestamp_ms'])/(b['timestamp_ms']-a['timestamp_ms'])
        return [ga['center'][k]+frac*(gb['center'][k]-ga['center'][k]) for k in range(2)]
    return None

def evaluate(frames,snapshots):
    last_ids={};switches=0;fp=0;matched=0;total=0;errors=[]
    for i,(frame,snap) in enumerate(zip(frames,snapshots)):
        pairs,nobs,ngt=matching(snap['tracks'],frame['truth']);fp+=nobs-len(pairs)
        matched+=len(pairs);total+=ngt
        for track,gt in pairs:
            if gt['id'] in last_ids and last_ids[gt['id']]!=track['id']:switches+=1
            last_ids[gt['id']]=track['id']
            future=future_truth(frames,i,gt['id'],frame['timestamp_ms']+400)
            if future is not None:errors.append(math.dist(track['prediction'],future))
    errors.sort()
    return dict(id_switches=switches,false_tracks=fp,matched_observations=matched,truth_observations=total,
                observed_recall=round(matched/total,4) if total else None,prediction_samples=len(errors),
                prediction_mae_px=round(sum(errors)/len(errors),4) if errors else None,
                prediction_p95_px=round(errors[int(.95*(len(errors)-1))],4) if errors else None,
                truth='exact_synthetic',horizon_ms=400)

def main():
    models={name:Tracker(name) for name in ('baseline','optimized')};index=[];metrics=[]
    for ident,title in SCENES:
        frames=synthetic(ident);snaps={}
        for model,tracker in models.items():
            tracker.reset();snaps[model]=[tracker.step(f['pixels'],f['ai'],f['ir'],f['timestamp_ms'],i) for i,f in enumerate(frames)]
        result={model:evaluate(frames,snapshots) for model,snapshots in snaps.items()}
        metrics.append(dict(id=ident,name=title,source='offline_synthetic',**result))
        folder=OUT/ident;folder.mkdir(exist_ok=True)
        data=[]
        for i,frame in enumerate(frames):
            (folder/f'{i}.png').write_bytes(png_gray(frame['pixels']))
            optimized=snaps['optimized'][i]
            optimized['baseline_tracks']=snaps['baseline'][i]['tracks']
            optimized['truth']=frame['truth']
            optimized['frame_url']=f'/replay/frame.png?scenario={ident}&seq={i}'
            data.append(dict(tracking=optimized,evaluation=result))
        (folder/'frames.json').write_text(json.dumps(data,separators=(',',':')),encoding='utf8')
        index.append(dict(id=ident,name=title,source='offline_synthetic',frames=len(frames),notes='合成矩形目标；不是现场人体精度'))
    recorded=HERE/'recordings_index.json'
    if recorded.exists():
        for ds in json.loads(recorded.read_text(encoding='utf8')).get('datasets',[]):
            ident=ds['id'];raw_path=Path(ds['raw_path']);raw=(raw_path if raw_path.is_absolute() else HERE/raw_path).read_bytes();n=ds['frames'];folder=OUT/ident;folder.mkdir(exist_ok=True)
            for t in models.values():t.reset()
            data=[]
            for i in range(n):
                pixels=raw[i*9216:(i+1)*9216];stamp=ds['timestamps_ms'][i]
                score=ds['ai_scores'][i] if ds['ai_scores'][i] is not None else -100
                old=models['baseline'].step(pixels,score,0,stamp,i);new=models['optimized'].step(pixels,score,0,stamp,i)
                new.update(source='offline_recording',baseline_tracks=old['tracks'],frame_url=f'/replay/frame.png?scenario={ident}&seq={i}',input_notes=ds.get('notes',''))
                (folder/f'{i}.png').write_bytes(png_gray(pixels));data.append(dict(tracking=new,evaluation={'truth':'unlabelled_recording','note':'缺少人工目标ID/框；不计算真人准确率或400ms误差'}))
            (folder/'frames.json').write_text(json.dumps(data,separators=(',',':')),encoding='utf8')
            index.append(dict(id=ident,name=ds['name'],source='offline_recording',frames=n,notes=ds.get('notes','')))
    (OUT/'index.json').write_text(json.dumps(index,ensure_ascii=False,indent=2),encoding='utf8')
    (HERE/'metrics.json').write_text(json.dumps(dict(source='offline',scenarios=metrics),ensure_ascii=False,indent=2),encoding='utf8')
    print(json.dumps(metrics,ensure_ascii=False,indent=2))

if __name__=='__main__':main()
