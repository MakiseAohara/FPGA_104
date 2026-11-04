"""Offline UART parser tests; no COM port or server is opened."""
import ast, re, copy, json
from pathlib import Path
root=Path(__file__).resolve().parents[2]
source=root/'tools/web_monitor.py'
tree=ast.parse(source.read_text(encoding='utf8'))
node=next(n for n in tree.body if isinstance(n,ast.ClassDef) and n.name=='BoardTrackParser')
ns=dict(re=re,copy=copy)
exec(compile(ast.Module(body=[node],type_ignores=[]),str(source),'exec'),ns)
Parser=ns['BoardTrackParser']
def trk(i=1,f=17,center=(20,30),miss=0,extra=''):
 return f'MMT_TRK f={f} id={i} c={center[0]},{center[1]} b=10,10,40,60 v16=32,-16 dir=5 hit=4 miss={miss} conf=1 pred=24,28 eta=2 '+extra
def mot(f=17,nt=1,extra=''):
 return f'MMT_MOT f={f} nd=1 nt={nt} conf=1 area=100 raw=100 pre=0 pre_eta=-1 obs=1 '+extra
p=Parser();assert p.feed(trk()) is None
first=p.feed(mot());assert first['algorithm']=='legacy_board' and first['time_step_ms'] is None
assert first['timestamp_ms'] is None and first['horizon_ms'] is None
assert first['frame_aligned'] is False and first['tracks'][0]['supported'] is None
p.feed(trk(center=(22,30)));second=p.feed(mot())
assert first['firmware_frame']==second['firmware_frame']==17
assert first['frame_id']!=second['frame_id'] and len(second['tracks'][0]['history'])==2
assert len(first['tracks'][0]['history'])==1,'old snapshots mutated'
for i in range(15):p.feed(trk(center=(25+i,30)));last=p.feed(mot())
assert len(last['tracks'][0]['history'])==12
p.feed(trk(miss=1));coast=p.feed(mot());assert coast['tracks'][0]['visible'] is False
assert coast['tracks'][0]['state']=='coasting' and len(coast['tracks'][0]['history'])==12
empty=p.feed(mot(nt=0));assert empty['tracks']==[] and p.history=={}
p.feed(trk());p.feed(mot());missing=p.feed(mot());assert missing['tracks']==[], 'unreported track remained displayed'
p.feed('MMT_BOOT ONCHIP_UART DDR3_WAIT');assert p.snapshot is None and p.pending=={}
p.feed(trk(extra='seq=1 t=1000 dt=125 step_ms=200 supported=1'))
timed=p.feed(mot(extra='seq=1 t=1000 dt=125 step_ms=200'))
assert timed['algorithm']=='timed_board' and timed['sample_ms']==125 and timed['time_step_ms']==200
assert timed['horizon_ms']==400 and timed['tracks'][0]['eta_ms']==400
p.feed(trk(extra='seq=2 t=1125'))
assert p.feed(mot(extra='seq=2 t=1125 step_ms=200'))['sample_ms']==125
p.feed(trk(extra='seq=2 t=1125'));assert p.feed(mot(extra='seq=2 t=1125 step_ms=200')) is None
p.feed(trk(i=1,extra='seq=3'));p.feed(trk(i=2,extra='seq=4'))
assert [t['id'] for t in p.feed(mot(extra='seq=4 t=1400 step_ms=200'))['tracks']]==[2]
event=p.feed('MMT_PREWARN f=17 id=2 eta=2 ms=1400 fw_lp=1')
assert event['prewarn']['active'] and event['prewarn']['action']=='prewarn_only'
wake=p.feed('MMT_LP_EXIT f=17 reason=prewarn ms=1401')
assert wake['prewarn']['action']=='wake_inference' and wake['prewarn']['id']==2
no=p.feed(mot(extra='seq=5 t=1500 step_ms=200'));assert no['prewarn']['active'] is False
p=Parser();p.feed(trk(extra='seq=4294967295'))
p.feed(mot(extra='seq=4294967295 t=4294967200 step_ms=200'))
p.feed(trk(extra='seq=0'));wrap=p.feed(mot(extra='seq=0 t=104 step_ms=200'))
assert wrap['sample_ms']==200 and wrap['frame_id']==0
assert Parser().feed('MMT_TRK f=1 id=1 c=bad b=1,2,3,4 v16=1,2 pred=2,3') is None
result=dict(passed=True,checks=['legacy timing unknown, not f-derived','repeated f separated by MOT boundary','immutable histories capped at 12 observations','coasting is not observation','empty and missing reports clear displayed tracks','boot reset','explicit 200 ms canonical velocity unit','actual dt timestamps','duplicate/out-of-order sequence rejection','mixed-step isolation','PREWARN and LP_EXIT evidence','32-bit wrap','malformed line rejection'])
(root/'evidence/mot_web_20261104/board_parser_test.json').write_text(json.dumps(result,indent=2),encoding='utf8')
print(json.dumps(result))
