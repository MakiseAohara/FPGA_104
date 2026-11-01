"""Host build of the board's TFLite Micro sources, with driver fallbacks only.

Hardware driver calls return OP_ERR, selecting the existing reference C++ kernels.
The model, shared input_contract.h, resolver, Invoke and output indexing are real.
This checks CPU inference; it does not claim to emulate the FPGA accelerator.
"""
from pathlib import Path
import concurrent.futures
import json
import os
import re
import subprocess
import shutil

HERE=Path(__file__).resolve().parent
ROOT=HERE.parents[1]
APP=Path(r'D:\FPGA\codex20\official-tinyml\tinyml_hello_world\Ti60F225_tinyml_hello_world\embedded_sw\SapphireSoc\software\standalone\tinyml_pdti8')
WORK=ROOT.parent/'v29_host_build'
WORK.mkdir(exist_ok=True)
overlay=WORK/'include';overlay.mkdir(exist_ok=True)
for header in (APP/'src').rglob('*.h'):
    target=overlay/header.relative_to(APP/'src');target.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(header,target)
(overlay/'vexriscv.h').write_text('#pragma once\n',encoding='utf-8')
(overlay/'riscv.h').write_text('#pragma once\n',encoding='utf-8')
(overlay/'clint.h').write_text('#pragma once\n',encoding='utf-8')
(overlay/'host_ops.h').write_text('#pragma once\ntypedef enum {OP_OK,OP_BYPASS,OP_ERR} OP_STATUS_T;\n',encoding='utf-8')
(overlay/'host_flags.h').write_text('#pragma once\n#define __attribute__(x)\n#define __x86_64__ 1\n#define __x86_64 1\n',encoding='utf-8')
(overlay/'bsp.h').write_text('#pragma once\n',encoding='utf-8')
(overlay/'print.h').write_text('#pragma once\n#include <cstdio>\n#define bsp_printf printf\n',encoding='utf-8')
(overlay/'intc.h').write_text('#pragma once\n',encoding='utf-8')
for header in (APP/'src/platform/tinyml/ops').glob('*.h'):
    relative=header.relative_to(APP/'src');target=overlay/relative;target.parent.mkdir(parents=True,exist_ok=True)
    names=set(re.findall(r'\b(\w+_drv)\s*\(',header.read_text(encoding='utf-8',errors='replace')))
    target.write_text('#pragma once\n#include "host_ops.h"\n'+''.join('template<typename... Args> static inline OP_STATUS_T '+name+'(Args...){return OP_ERR;}\n' for name in names),encoding='utf-8')
vs=Path(r'C:\Program Files\Microsoft Visual Studio\2022\Community')
vc=vs/'VC/Tools/MSVC/14.44.35207'
kit=Path(r'C:\Program Files (x86)\Windows Kits\10')
version='10.0.26100.0'
env=os.environ.copy();env['PATH']=str(vc/'bin/Hostx64/x64')+';'+env['PATH']
env['INCLUDE']=';'.join(map(str,[vc/'include',kit/'Include'/version/'ucrt',kit/'Include'/version/'shared',kit/'Include'/version/'um']))
env['LIB']=';'.join(map(str,[vc/'lib/x64',kit/'Lib'/version/'ucrt/x64',kit/'Lib'/version/'um/x64']))
commands=json.loads((ROOT.parent/'v29_bright_build/compile_commands.json').read_text(encoding='utf-8'))
sources=[Path(c[c.index('-c')+1]) for c in commands if '/tensorflow/' in c[c.index('-c')+1].replace('\\','/')]
wanted={'conv.cc','conv_common.cc','fully_connected.cc','fully_connected_common.cc','reduce.cc','reduce_common.cc','softmax.cc','softmax_common.cc','kernel_util.cc'}
sources=[p for p in sources if ('micro/kernels/' not in p.as_posix() or p.name in wanted) and p.name not in ('all_ops_resolver.cc','test_helpers.cc','mock_micro_graph.cc')]
allocator=next(p for p in sources if p.name=='micro_allocator.cc')
text=allocator.read_text(encoding='utf-8').replace('const TfLiteIntArray kZeroLengthIntArray = {};','static const int host_empty_dimensions[2]={0,0};\n#define kZeroLengthIntArray (*reinterpret_cast<const TfLiteIntArray*>(host_empty_dimensions))')
copy=WORK/'micro_allocator.cc';copy.write_text(text,encoding='utf-8');sources=[copy if p==allocator else p for p in sources]
sources += [HERE/'offline_invoke.cc',HERE/'generator/v29_person_96_int8_model_data.cc']
includes=[overlay,HERE,APP/'src',APP/'src/tensorflow/third_party/flatbuffers/include',APP/'src/tensorflow/third_party/gemmlowp',APP/'src/tensorflow/third_party/ruy']
flags=['/nologo','/O2','/EHsc','/std:c++20','/TP','/DTF_LITE_STATIC_MEMORY','/DTF_LITE_DISABLE_X86_NEON','/D_CRT_SECURE_NO_WARNINGS','/FI'+str(overlay/'host_flags.h'),*['/I'+str(p) for p in includes]]
def compile_one(pair):
    i,source=pair;obj=WORK/f'{i:03d}.obj'
    command=[str(vc/'bin/Hostx64/x64/cl.exe'),*flags,'/c',str(source),'/Fo'+str(obj)]
    result=subprocess.run(command,env=env,capture_output=True,timeout=90)
    (WORK/f'{i:03d}.log').write_bytes(result.stdout+result.stderr)
    return dict(source=str(source),object=str(obj),returncode=result.returncode,log=(result.stdout+result.stderr).decode(errors='replace'))
with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:results=list(pool.map(compile_one,enumerate(sources)))
failed=[r for r in results if r['returncode']]
(HERE/'host_build_results.json').write_text(json.dumps(results,indent=2),encoding='utf-8')
print('HOST_COMPILE',len(sources),'FAILURES',len(failed),flush=True)
for row in failed[:4]:print(row['source'],row['log'][-3500:],flush=True)
if failed:raise SystemExit(1)
command=[str(vc/'bin/Hostx64/x64/link.exe'),'/NOLOGO','/OUT:'+str(WORK/'offline_invoke.exe'),*[r['object'] for r in results]]
result=subprocess.run(command,env=env,capture_output=True,timeout=90)
(HERE/'host_link.log').write_bytes(result.stdout+result.stderr);print((result.stdout+result.stderr).decode(errors='replace'));raise SystemExit(result.returncode)
