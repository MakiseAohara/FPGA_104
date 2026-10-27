"""Run actual extracted v26/v28 C against v27 fixed inputs; label by buttons."""
import csv
import datetime as dt
import hashlib
import importlib.util
import json
from pathlib import Path
import re
import struct
import subprocess
import sys

sys.dont_write_bytecode=True
HERE=Path(__file__).resolve().parent
ROOT=HERE.parents[1]
WORK=ROOT.parent/'v28_replay_build'
TC=Path(r'D:\riscv\xpack-riscv-none-elf-gcc-15.2.0-1\bin')
sys.path.insert(0,str(ROOT.parent/'v23_vendor'))
from unicorn import Uc,UC_ARCH_RISCV,UC_MODE_RISCV32
from unicorn.riscv_const import UC_RISCV_REG_SP,UC_RISCV_REG_RA,UC_RISCV_REG_PC
spec=importlib.util.spec_from_file_location('actual_c',ROOT/'evidence/v23_offline/replay_actual_c.py')
actual=importlib.util.module_from_spec(spec);spec.loader.exec_module(actual)


def read_csv(path):
    with path.open(encoding='utf-8-sig',newline='') as stream:return list(csv.DictReader(stream))


def compile_code(text,out,name='decision'):
    out.mkdir(parents=True,exist_ok=True)
    c=out/(name+'.c');elf=out/(name+'.elf');binary=out/(name+'.bin')
    c.write_text(text,encoding='utf-8',newline='\n')
    command=[str(TC/'riscv-none-elf-gcc.exe'),'-O2','-std=c99','-march=rv32im','-mabi=ilp32',
             '-msmall-data-limit=0','-mno-relax','-ffreestanding','-fno-builtin','-nostdlib',
             '-Wl,--no-relax,-Ttext=0x10000,--entry=replay_frame',str(c),'-lgcc','-o',str(elf)]
    result=subprocess.run(command,capture_output=True,timeout=60)
    (out/(name+'_build.log')).write_bytes(result.stdout+result.stderr);result.check_returncode()
    subprocess.run([str(TC/'riscv-none-elf-objcopy.exe'),'-O','binary',str(elf),str(binary)],check=True)
    nm=subprocess.check_output([str(TC/'riscv-none-elf-nm.exe'),'-n',str(elf)],text=True)
    symbols={v[2]:int(v[0],16) for line in nm.splitlines() if len(v:=line.split())==3 and re.fullmatch('[0-9a-fA-F]+',v[0])}
    u=Uc(UC_ARCH_RISCV,UC_MODE_RISCV32);u.mem_map(0x10000,0x80000);u.mem_write(0x10000,binary.read_bytes())
    u.mem_map(0x800000,0x10000);u.reg_write(UC_RISCV_REG_SP,0x80fff0)
    return u,symbols


class Model:
    def __init__(self,source,name):
        text=source.read_text(encoding='utf-8-sig')
        definitions=[line for line in text.splitlines() if re.match(r'#define\s+(?:AI_|IR_|DEC_|FW_DECISION_ON)\w*\s+\(?-?\d+',line)]
        globals_text=text[text.index('static int ai_hist['):text.index('static int ai_vote_update(')]
        functions='\n'.join(actual.function(text,name) for name in ['ai_vote_update','ai_reset','dec_update'])
        harness='''#include <stdint.h>
static uint32_t simulated_time;
static uint64_t now_ms(void){return simulated_time;}
static void bsp_printf(const char* fmt,...){(void)fmt;}
static volatile uint32_t dec_reg,ctrl_reg;
#define APB_DEC dec_reg
#define APB_CTRL ctrl_reg
'''+ '\n'.join(definitions)+'\n'+globals_text+functions+'''
volatile int input_data[10],output_data[6];
void replay_frame(void){
 int person=0;
 if(input_data[0]){
  ai_reset();alarm_on=0;alarm_frames=0;cand_left=0;rel_cnt=0;last_person=0;dec_evt=0;dec_conf=0;
#ifdef IR_OFF_WIN
  ir_idx=0;ir_cnt10=0;ir_cnt15=0;for(int i=0;i<IR_OFF_WIN;i++)ir_hist[i]=0;
#endif
 }
 if(input_data[3]){ai_reset();last_person=0;}
 if(input_data[2])person=ai_vote_update(input_data[1]);
 last_person=person;simulated_time=input_data[9];
 dec_update(input_data[7],input_data[5],input_data[8],input_data[2],person,input_data[4],input_data[6]);
 output_data[0]=alarm_on;output_data[1]=cand_left;output_data[2]=rel_cnt;output_data[3]=person;
#ifdef IR_OFF_WIN
 output_data[4]=ir_cnt10;output_data[5]=ir_cnt15;
#else
 output_data[4]=0;output_data[5]=0;
#endif
}
'''
        self.u,self.symbols=compile_code(harness,WORK/name)
        self.functions_sha256=hashlib.sha256(functions.encode()).hexdigest()

    def step(self,reset=0,p=-128,infer=1,reset_ai=0,lp=0,motion=0,area=500,score=0,ir=0,t=0):
        values=[reset,p,infer,reset_ai,lp,motion,area,score,ir,t]
        self.u.mem_write(self.symbols['input_data'],struct.pack('<10i',*values))
        self.u.reg_write(UC_RISCV_REG_RA,0x8fff0)
        self.u.emu_start(self.symbols['replay_frame'],0x8fff0,count=50000)
        assert self.u.reg_read(UC_RISCV_REG_PC)==0x8fff0
        return struct.unpack('<6i',self.u.mem_read(self.symbols['output_data'],24))


def checks(model):
    assert model.step(reset=1,p=127,motion=0)[0]==0
    assert model.step(reset=1,p=60,motion=1)[0]==1
    assert model.step(reset=1,p=-61,motion=1,ir=1)[0]==0
    assert model.step(p=-61,ir=1)[0]==1
    for i in range(14):assert model.step(p=-61,ir=0)[0]==1,(i,'IR release too early')
    assert model.step(p=-61,ir=0)[0]==0
    model.step(reset=1,p=60,motion=1)
    for i in range(20):assert model.step(p=-60)[0]==1,'Strict < -60 required'
    low=model.step(infer=0,reset_ai=1,lp=1,ir=1)
    assert low[0]==0 and low[2]==0 and low[4:]==(0,0)
    assert model.step(p=-61,motion=1,ir=1)[0]==0,'No IR retained across LP'
    model.step(reset=1,p=-128,motion=1,ir=1)
    for i in range(8):model.step(p=-128,ir=0)
    assert model.step(p=-128,motion=1,ir=1)[0]==1,'Both ones inside last 10'
    model.step(reset=1,p=-128,motion=1,ir=1)
    for i in range(9):model.step(p=-128,ir=0)
    assert model.step(p=-128,motion=1,ir=1)[0]==0,'First one aged out of last 10'
    return ['motion candidate required even for strong AI','single p=60 starts without person vote',
            'two IR positives start without AI person','15 IR zeros required for release','AI=-60 does not release',
            'LP forces release and clears IR/AI','10-sample ring boundary']


def main():
    data=ROOT/'evidence/v27_gate'
    ticks=read_csv(data/'ticks.csv')
    raw={};samples={}
    for line in (data/'log_v27_gate.log').read_bytes().decode('utf-8').split('\n'):
        if '\t' not in line:continue
        wall,body=line.split('\t',1);fields=dict(actual.KV.findall(body))
        if body.startswith('MMT_AI '):samples[int(fields['f'])]=fields
        if body.startswith('MMT_DEC '):raw[int(fields['t'])]=(wall,fields)
    manual=read_csv(data/'manual_events_raw.csv')
    results={}
    saved={}
    for name,path in [('v26',ROOT/'evidence/v26_gate/main_live26.cc'),('v28',HERE/'main_live28.cc')]:
        model=Model(path,name);rows=[];mismatches=[];previous_lp=0
        for index,tick in enumerate(ticks):
            t=int(tick['device_ms']);wall,fields=raw[t];low=int(tick['lp']);sample=samples.get(int(fields['f']))
            assert bool(sample)==(low==0),'Incomplete inference schedule'
            out=model.step(reset=int(index==0),p=int(sample['p']) if sample else -128,infer=int(sample is not None),
                reset_ai=int(low and not previous_lp),lp=low,motion=int(tick['motion']),area=int(tick['area']),
                score=int(fields['score']),ir=int(fields['irhot']),t=t)
            previous_lp=low
            if name=='v26' and out[:4]!=tuple(int(fields[key]) for key in ['alarm_req','cand','rel','person']):
                mismatches.append(dict(t=t,c=list(out[:4]),logged=[fields[key] for key in ['alarm_req','cand','rel','person']]))
            rows.append(dict(device_ms=t,wall=wall,alarm=out[0],cand=out[1],rel=out[2],person=out[3],ir_cnt=out[4],ir_cnt15=out[5],lp=low))
        directory=HERE/'replay'/name;directory.mkdir(parents=True,exist_ok=True)
        with (directory/'ticks_replayed.csv').open('w',encoding='utf-8',newline='') as stream:
            writer=csv.DictWriter(stream,fieldnames=list(rows[0]));writer.writeheader();writer.writerows(rows)
        shutil_source=WORK/name/'decision.c'
        (directory/'actual_decision.c').write_bytes(shutil_source.read_bytes())
        (directory/'replay_build.log').write_bytes((WORK/name/'decision_build.log').read_bytes())
        results[name]=dict(dec_records=len(rows),baseline_mismatches=mismatches,functions_sha256=model.functions_sha256)
        saved[name]=rows
        if name=='v28':results[name]['actual_c_boundary_checks']=checks(model)
    assert not results['v26']['baseline_mismatches'],'v26 baseline must reproduce the observed data'
    assert [r['person'] for r in saved['v26']]==[r['person'] for r in saved['v28']]
    for name,rows in saved.items():
        phase='unlabelled';chair=False;position=0;group={k:dict(ticks=0,alarm_ticks=0,duration_ms=0,alarm_ms=0) for k in ['person','empty','unlabelled','chair']}
        for index,row in enumerate(rows):
            while position<len(manual) and manual[position]['wall']<=row['wall']:
                event=manual[position]['event']
                if event=='ENTER':phase='person'
                elif event in ('LEAVE','EMPTY_CONFIRMED'):phase='empty'
                elif event=='CHAIR_START':chair=True
                elif event=='CHAIR_END':chair=False
                position+=1
            duration=rows[index+1]['device_ms']-row['device_ms'] if index+1<len(rows) else 0
            for key in [phase]+(['chair'] if chair else []):
                item=group[key];item['ticks']+=1;item['alarm_ticks']+=row['alarm'];item['duration_ms']+=duration;item['alarm_ms']+=duration*row['alarm']
        results[name]['by_last_operator_label']=group
        results[name]['presence_coverage_tick_percent']=100*group['person']['alarm_ticks']/group['person']['ticks']
        results[name]['presence_coverage_time_percent']=100*group['person']['alarm_ms']/group['person']['duration_ms']
    result=dict(method='actual extracted C functions under RV32IM Unicorn; fixed v27 inputs, not a Python reimplementation',
        input_sha256={name:hashlib.sha256((data/name).read_bytes()).hexdigest() for name in ['ticks.csv','log_v27_gate.log','manual_events_raw.csv']},
        versions=results,label_policy='last E/L/Space continued; initial state unknown; chair separately overlaid; duplicate/missing inputs not repaired',
        limitations='v27 has duplicate ENTER and no ENTER before head/side after last LEAVE; metrics describe button labels, not independently verified physical truth',
        fixed_input_schedule='AI on-votes/person are unchanged and equal in both replays, so observed LP/inference schedule is retained',
        ir_initialization='zero-filled ring at boot and during LP; IR_OFF_WIN tests all ring entries, with no separate fill gate')
    (HERE/'replay_results.json').write_text(json.dumps(result,ensure_ascii=False,indent=2)+'\n',encoding='utf-8',newline='\n')
    print(json.dumps(result,ensure_ascii=False))


if __name__=='__main__':main()
