import ast, re, time, struct, zlib
from pathlib import Path

source=Path(__file__).resolve().parents[2]/'tools/web_monitor.py'
tree=ast.parse(source.read_text(encoding='utf8'))
functions=[n for n in tree.body if isinstance(n,ast.FunctionDef) and n.name in ('handle','png_gray')]
state={'lowpwr':0,'series':[],'obs':0}
scope=dict(re=re,time=time,struct=struct,zlib=zlib,state=state,stats={},frame_png=[None],add_event=lambda *a,**kw:None)
exec(compile(ast.Module(body=functions,type_ignores=[]),str(source),'exec'),scope)
handle=scope['handle']
handle('MMT_LP f=60 lowpwr=0 fw_lp=0 paused=0 camfps=60 inf_hz=2 ddr_ar_s=123 tml_ar_s=0 infer=44 sht_upd=1 ir_upd=52 sht=250 rh=625 body=262 vts=0x000005dc')
assert state['sht']==250 and state['rh']==625 and state['body']==262
assert state['camfps']==60 and state['inf_hz']==2
handle('MMT_MOT f=60 nd=2 nt=2 conf=60 area=50 raw=123 pre=0 pre_eta=-1 obs=76')
assert state['nd']==2 and state['nt']==2 and state['obs']==76 and state['series'][-1]['obs']==76
handle('MMT_AI f=60 p=-57 th=0 vote=2/3 person=0')
assert state['p']==-57
handle('MMT_THUMB t=20 f=60 alarm=0 p=-57 '+('7f'*(48*27)))
png=scope['frame_png'][0]
assert struct.unpack('!II',png[16:24])==(192,108)
handle('MMT_THUMB t=20 f=60 alarm=0 p=-57 f')
assert scope['frame_png'][0]==png
print('PASS actual UART LP sensor fields, MOT obs, signed AI, 16:9 thumbnail, damaged line handling')
