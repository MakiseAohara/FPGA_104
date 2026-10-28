"""Close-file derivation and independent checks, with explicit protocol deviations."""
from pathlib import Path
import csv
import hashlib
import json
import re
import statistics
import subprocess
import sys
from collections import defaultdict,Counter

ROOT=Path(__file__).resolve().parents[2]
GATE=ROOT/'evidence/v29_gate'
FW=ROOT/'evidence/v29_fw'
meta=json.loads((GATE/'run_metadata.json').read_text(encoding='utf-8'))
assert meta['port_closed']
free=next(row for row in meta['phases'] if row['phase']=='FREE_MOVEMENT')
assert free['elapsed_seconds']>=1799
for script in ('build_v29_gate.py','derive_thumbs.py','verify_v29_gate.py'):
    p=subprocess.run([sys.executable,str(GATE/script),'--evidence',str(GATE)],capture_output=True)
    (GATE/(script.removesuffix('.py')+'_stdout.log')).write_bytes(p.stdout+p.stderr)
    print(script,p.returncode,(p.stdout+p.stderr).decode(errors='replace')[-450:],flush=True)
    p.check_returncode()
KV=re.compile(r'\b([A-Za-z_][A-Za-z0-9_]*)=([^\s]+)')
phases=meta['phases'];ir=defaultdict(Counter);means=defaultdict(list)
events=[];boots=[];presets=[];pending=None;sid=0;scope_host=[];last_end=None;interruptions=[]
for line in (GATE/'log_v29_gate.log').read_bytes().decode('utf-8').split('\n'):
    if '\t' not in line:continue
    wall,body=line.split('\t',1);body=body.strip('\r');f=dict(KV.findall(body))
    if body.startswith('MMT_LIVE_BOOT v29 '):sid+=1;boots.append(dict(wall=wall,text=body))
    if body.startswith('MMT_CAM_PRESET '):presets.append(dict(wall=wall,**f))
    if body.startswith('### CAPTURE_END'):last_end=wall
    if body.startswith('### RESUME_CAPTURE') and last_end:
        import datetime as dt
        interruptions.append(dict(start_wall=last_end,end_wall=wall,seconds=(dt.datetime.fromisoformat(wall)-dt.datetime.fromisoformat(last_end)).total_seconds()))
    if body.startswith('### RECONNECT_TRY'):pending=None
    if body.startswith(('### GAP ','### RECONNECTED ')):scope_host.append(dict(wall=wall,text=body))
    if body.startswith('MMT_PP '):pending=f
    if body.startswith('MMT_DEC '):
        for phase in phases:
            if phase['start_wall']<=wall<=phase['end_wall']:ir[phase['phase']][f['irhot']]+=1
        if pending and 'mean_sensor' in pending:
            means[(sid,int(f['t'])//60000)].append(int(pending['mean_sensor']));pending=None
def write(name,columns,rows):
    with (GATE/name).open('w',encoding='utf-8',newline='') as stream:
        w=csv.DictWriter(stream,fieldnames=columns,extrasaction='ignore');w.writeheader();w.writerows(rows)
write('phase_ir_observations.csv',['phase','irhot','ticks','scene_truth'],[dict(phase=p,irhot=k,ticks=n,scene_truth='planned phase only; Claude reviews images') for p,counts in ir.items() for k,n in sorted(counts.items())])
write('mean_sensor_60s.csv',['session','device_start_ms','samples','median'],[dict(session=s,device_start_ms=m*60000,samples=len(v),median=statistics.median(v)) for (s,m),v in sorted(means.items())])
write('recorder_interruptions.csv',['start_wall','end_wall','seconds'],interruptions)
scope=[e for e in scope_host if free['start_wall']<=e['wall']<=free['end_wall']]
with (GATE/'thumbs.csv').open(encoding='utf-8') as stream:thumbs=list(csv.DictReader(stream))
free_thumbs=[row for row in thumbs if free['start_wall']<=row['wall']<=free['end_wall']]
with (GATE/'frames.csv').open(encoding='utf-8') as stream:frames=list(csv.DictReader(stream))
verification=json.loads((GATE/'verification.json').read_text(encoding='utf-8'))
facts=dict(selected_preset=meta['selected_preset'],firmware=meta['firmware'],free_capture=free,
    total_thumbnails=len(thumbs),free_thumbnails=len(free_thumbs),total_full_frames=len(frames),
    free_gap_lines=sum(e['text'].startswith('### GAP ') for e in scope),
    free_reconnects=sum(e['text'].startswith('### RECONNECTED ') for e in scope),
    recorder_interruptions=interruptions,offline_check_passed=False,truth_source='Claude reviews images')
(GATE/'gate_facts.json').write_text(json.dumps(facts,indent=2)+'\n',encoding='utf-8')
summary=(GATE/'summary.md').read_text(encoding='utf-8')
prefix=['# v29 上板记录（事实）','',
 f"自由走动：{free['start_wall']} → {free['end_wall']}，墙钟 {free['elapsed_seconds']} 秒。",
 f"板上保持 {meta['selected_preset']}，CRC32 {meta['firmware']['crc32']}；VTS=1500、exp20=47824、gc=0x81、gf=0x2A。",
 f"缩略图共 {len(thumbs)} 张，其中自由走动时段 {len(free_thumbs)} 张；96×96 共 {len(frames)} 张。",
 f"自由走动时段 GAP={facts['free_gap_lines']}、自动重连={facts['free_reconnects']}。完整日志还包含 NIGHT/DAY 加载和先期检查。",
 '',
 'NIGHT 的亮度读数超过 130 后切 DAY；DAY 先期检查也出现超过 130。最初记录器额外设置的 DAY 高亮终止条件导致暂停，随后依用户“遇到问题写明继续下一项”直接重连，不再烧录/复位。暂停缺测见 recorder_interruptions.csv，未补写串口数据。亮度检查因上述暂停未按原计划连续记录满两分钟。',
 '方向提示窗口的 AI 分数中位数：空场 -112，有人 -77.5；提示窗口不是人体真值，预期正负分离未得到确认。没有根据分数或计划时间生成实际进出标签。',
 '离线 TF2.16.1 ±1 核对未通过（38/55，最大差 6）；在告知后用户又明确指令“串口重新连接，上板”，据此记录候选诊断。有效性与判定由 Claude 看图分析。',
 '',
 '每 60 秒 mean_sensor 中位数见 mean_sensor_60s.csv；各提示阶段及自由走动的 irhot 分布见 phase_ir_observations.csv，阶段名称不代表已验证场景。','',
 '## 启动预设读数','']
prefix += ['- '+json.dumps(row,ensure_ascii=False) for row in presets]
(GATE/'summary.md').write_text('\n'.join(prefix)+'\n\n'+summary,encoding='utf-8')
note=ROOT/'comms/codex/20261028_v29_build_and_board.md'
text=note.read_text(encoding='utf-8').split('\n最终采集闭合：',1)[0]
text+=f"\n最终采集闭合：{free['start_wall']} 至 {free['end_wall']}，{free['elapsed_seconds']} 秒；DAY {meta['firmware']['crc32']}。导出缩略图 {len(thumbs)} 张（自由段 {len(free_thumbs)}）、96×96 {len(frames)} 张；自由段 GAP={facts['free_gap_lines']}、重连={facts['free_reconnects']}，原始 UART 及缩略图逐字节验证完成。亮度检查提前中断和 {interruptions} 的记录器缺测均已保留，未伪称完成了连续两分钟亮度检查；没有额外调参。真值与有效性由 Claude 看图。\n"
note.write_text(text,encoding='utf-8')
(GATE/'README.md').write_text('v29 原始 UART、ticks/AI、完整 96×96 图、48×48 灰度放大缩略图及每页60张总览。PNG保留原始u字节，不加128。summary.md 记录预设切换、方向窗口未确认、离线超差和记录器暂停；run_metadata.json/phase_events.json 只记计划阶段，不是真值标签。Claude 按图评估。\n',encoding='utf-8')
files={p.relative_to(GATE).as_posix():dict(bytes=p.stat().st_size,sha256=hashlib.sha256(p.read_bytes()).hexdigest()) for p in GATE.rglob('*') if p.is_file() and '__pycache__' not in p.parts and p.name!='manifest.json'}
(GATE/'manifest.json').write_text(json.dumps(dict(facts=facts,verification=verification,files=files),indent=2)+'\n',encoding='utf-8')
print('FINAL_FACTS',json.dumps(facts),flush=True)
