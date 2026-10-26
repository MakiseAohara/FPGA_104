"""Replay logged v19 inputs through the actual C voting/decision functions.

Only standalone PC-side simulation code is built. Firmware image and source
remain untouched. Unknown initial state is excluded until a boot or an observed
paused checkpoint; the checkpoint frame itself is not counted as a comparison.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import struct
import subprocess
import sys

KV=re.compile(r"\b([A-Za-z_][A-Za-z0-9_]*)=([^\s]+)")


def function(source, name):
    start=re.search(r"static\s+(?:int|void)\s+"+name+r"\s*\(",source).start()
    brace=source.index("{",start)
    depth=1
    end=brace+1
    while depth:
        depth+=(source[end]=="{")-(source[end]=="}")
        end+=1
    return source[start:end]


def compile_model(a):
    src=a.source.read_text(encoding="utf-8-sig")
    defines=[]
    constants={}
    for line in src.splitlines():
        match=re.match(r"#define\s+((?:AI_|DEC_|FW_DECISION_ON)\w*)\s+\(?(-?\d+)\)?",line)
        if match:
            defines.append(line)
            constants[match[1]]=int(match[2])
    globals_start=src.index("static int ai_hist[")
    globals_end=src.index("static int ai_vote_update(")
    functions="\n".join(function(src,n) for n in ("ai_vote_update","ai_reset","dec_update"))
    code="""#include <stdint.h>
static uint32_t simulated_time;
static uint64_t now_ms(void){return simulated_time;}
static void bsp_printf(const char *fmt,...){(void)fmt;}
static volatile uint32_t dec_reg, ctrl_reg;
#define APB_DEC dec_reg
#define APB_CTRL ctrl_reg
"""+"\n".join(defines)+"\n"+src[globals_start:globals_end]+functions+"""
typedef struct { int action,p,infer,reset_ai,lp,motion,area,score,
                     seed_alarm,seed_cand,seed_rel,time; } replay_input;
typedef struct { int alarm,cand,rel,person; } replay_output;
volatile replay_input input_data;
volatile replay_output output_data;
void replay_frame(void) {
  int person=0;
  if(input_data.action==1){
    ai_reset(); alarm_on=0; alarm_frames=0; cand_left=0; rel_cnt=0;
    last_person=0; dec_evt=0; dec_conf=0;
  }
  if(input_data.action==2){
    ai_reset(); alarm_on=input_data.seed_alarm; cand_left=input_data.seed_cand;
    rel_cnt=input_data.seed_rel; last_person=0;
  } else {
    if(input_data.reset_ai){ai_reset();last_person=0;}
    if(input_data.infer) person=ai_vote_update(input_data.p);
    last_person=person; simulated_time=(uint32_t)input_data.time;
    dec_update(input_data.score,input_data.motion,0,input_data.infer,person,
               input_data.lp,input_data.area);
  }
  output_data.alarm=alarm_on; output_data.cand=cand_left;
  output_data.rel=rel_cnt; output_data.person=last_person;
}
"""
    a.work.mkdir(parents=True,exist_ok=True)
    c=a.work/"actual_v19_decision.c"
    c.write_text(code,encoding="utf-8",newline="\n")
    elf=a.work/"actual_v19_decision.elf"
    command=[str(a.toolchain/"riscv-none-elf-gcc.exe"),"-O2","-std=c99","-march=rv32im","-mabi=ilp32",
             "-msmall-data-limit=0","-mno-relax","-ffreestanding","-fno-builtin","-nostdlib",
             "-Wl,--no-relax,-Ttext=0x10000,--entry=replay_frame",str(c),"-lgcc","-o",str(elf)]
    build=subprocess.run(command,capture_output=True,timeout=60)
    (a.out/"replay_c_build.log").write_bytes(build.stdout+build.stderr)
    build.check_returncode()
    binary=a.work/"actual_v19_decision.bin"
    subprocess.run([str(a.toolchain/"riscv-none-elf-objcopy.exe"),"-O","binary",str(elf),str(binary)],check=True,timeout=20)
    nm=subprocess.run([str(a.toolchain/"riscv-none-elf-nm.exe"),"-n",str(elf)],capture_output=True,text=True,check=True)
    symbols={v[2]:int(v[0],16) for line in nm.stdout.splitlines() if len(v:=line.split())==3 and re.fullmatch("[0-9a-fA-F]+",v[0])}
    return binary.read_bytes(),symbols,constants,hashlib.sha256(functions.encode()).hexdigest()


def read_epochs(path):
    epochs=[{"known_boot":False,"frames":{}}]
    last_f=None
    for line_n,raw in enumerate(path.read_bytes().decode("utf-8-sig",errors="replace").split("\n"),1):
        text=raw.split("\t",1)[-1].strip()
        tag=text.split(" ",1)[0]
        fields=dict(KV.findall(text))
        if tag in ("MMT_LIVE_BOOT","MMT_BOOT"):
            epochs.append({"known_boot":tag=="MMT_LIVE_BOOT","frames":{}})
            last_f=None
        if tag not in ("MMT_AI","MMT_OSD","MMT_LP","MMT_LP_ENTER","MMT_LP_EXIT","MMT_DEC") or "f" not in fields:
            continue
        f=int(fields["f"])
        if last_f is not None and f<last_f:
            epochs.append({"known_boot":False,"frames":{}})
        last_f=f
        row=epochs[-1]["frames"].setdefault(f,{"f":f,"tags":{}})
        row["tags"][tag]=fields
        if tag=="MMT_DEC": row["line"]=line_n
    return [e for e in epochs if any("MMT_DEC" in r["tags"] for r in e["frames"].values())]


def replay(a,code,symbols,path):
    from unicorn import Uc,UC_ARCH_RISCV,UC_MODE_RISCV32
    from unicorn.riscv_const import UC_RISCV_REG_SP,UC_RISCV_REG_RA,UC_RISCV_REG_PC
    comparisons=skipped=syncs=total=0
    mismatches=[]
    epochs=read_epochs(path)
    for epoch in epochs:
        u=Uc(UC_ARCH_RISCV,UC_MODE_RISCV32)
        u.mem_map(0x10000,0x40000);u.mem_write(0x10000,code)
        u.mem_map(0x800000,0x10000);u.reg_write(UC_RISCV_REG_SP,0x80fff0)
        known=epoch["known_boot"]
        first=True
        rows=sorted((r for r in epoch["frames"].values() if "line" in r),key=lambda r:r["line"])
        for row in rows:
            total+=1
            tags=row["tags"];dec=tags["MMT_DEC"];lp=tags.get("MMT_LP",{})
            low=int(any(int(lp.get(k,0)) for k in ("fw_lp","lowpwr","paused")))
            ai=tags.get("MMT_AI",tags.get("MMT_OSD",{}))
            inferred="p" in ai
            if not low and not inferred:
                skipped+=1;known=False;continue
            action=1 if first and known else 0
            first=False
            if not known:
                if not low:
                    skipped+=1;continue
                action=2;syncs+=1;known=True
            values=[action,int(ai.get("p",0)),int(inferred),int("MMT_LP_ENTER" in tags),low,
                    int(dec["motion"]),int(dec["area"]),int(dec["score"]),
                    int(dec["alarm_req"]),int(dec["cand"]),int(dec["rel"]),int(dec["t"])]
            u.mem_write(symbols["input_data"],struct.pack("<12i",*values))
            u.reg_write(UC_RISCV_REG_RA,0x4fff0)
            u.emu_start(symbols["replay_frame"],0x4fff0,count=20000)
            if u.reg_read(UC_RISCV_REG_PC)!=0x4fff0:raise RuntimeError("Replay did not return")
            expected=struct.unpack("<4i",u.mem_read(symbols["output_data"],16))
            observed=tuple(int(dec[k]) for k in ("alarm_req","cand","rel","person"))
            if action==2:continue
            comparisons+=1
            if expected!=observed:
                mismatches.append({"line":row["line"],"f":row["f"],"device_ms":int(dec["t"]),
                                   "fields":["alarm","cand","rel","person"],"c_output":expected,"logged":observed})
    return {"file":str(path),"sha256":hashlib.sha256(path.read_bytes()).hexdigest(),"dec_records":total,
            "compared_records":comparisons,"unknown_or_missing_input_records":skipped,
            "paused_checkpoint_records":syncs,"epochs":len(epochs),"mismatches":mismatches}


def main(a):
    sys.path.insert(0,str(a.vendor.resolve()))
    a.out.mkdir(parents=True,exist_ok=True)
    code,symbols,constants,functions_sha=compile_model(a)
    logs=[a.repo/"evidence/v19_board/log_v19_A_dump.log",a.repo/"evidence/v19_board/log_v19_B_official.log",
          a.repo/"evidence/v22_gate/log_v22_gate.log"]
    result={"source":str(a.source),"source_sha256":hashlib.sha256(a.source.read_bytes()).hexdigest(),
            "decision_functions_sha256":functions_sha,"constants":constants,
            "method":"execute unmodified extracted C functions under RV32IM; no firmware rebuild",
            "checkpoint_policy":"exclude unknown prefix; synchronize only once at an observed paused frame per unknown epoch",
            "logs":[replay(a,code,symbols,p) for p in logs],"board_access":False,"detector_performance_assessed":False}
    (a.out/"decision_replay.json").write_text(json.dumps(result,indent=2)+"\n",encoding="utf-8",newline="\n")
    for log in result["logs"]:
        print(Path(log["file"]).name,"records",log["dec_records"],"compared",log["compared_records"],
              "checkpoints",log["paused_checkpoint_records"],"mismatches",len(log["mismatches"]))


if __name__=="__main__":
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument("--repo",type=Path,required=True);p.add_argument("--source",type=Path,required=True)
    p.add_argument("--vendor",type=Path,required=True);p.add_argument("--work",type=Path,required=True)
    p.add_argument("--out",type=Path,required=True)
    p.add_argument("--toolchain",type=Path,default=Path(r"D:\riscv\xpack-riscv-none-elf-gcc-15.2.0-1\bin"))
    main(p.parse_args())
