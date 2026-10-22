"""Build the official Ti60 fixed-image example without make/MSYS dependencies."""
import argparse
from concurrent.futures import ThreadPoolExecutor
import hashlib
import json
from pathlib import Path
import subprocess

ap=argparse.ArgumentParser()
ap.add_argument('--project',type=Path,required=True)
ap.add_argument('--toolchain',type=Path,required=True)
ap.add_argument('--out',type=Path,required=True)
ap.add_argument('--main-source',type=Path)
args=ap.parse_args()
p=args.project
stand=p/'embedded_sw/SapphireSoc/software/standalone'
bsp=p/'embedded_sw/SapphireSoc/bsp/efinix/EfxSapphireSoc'
app=stand/'tinyml_pdti8'
out=args.out
out.mkdir(parents=True,exist_ok=True)
def run(cmd):
    return subprocess.run(list(map(str,cmd)),cwd=app,capture_output=True,text=True,errors='replace',timeout=120)
common=['-march=rv32im_zicsr_zifencei','-mabi=ilp32','-O3','-g','-DOPTIMIZE_X',
    '-funroll-loops','-mdiv','-ffunction-sections','-fdata-sections','-fno-common',
    '-fomit-frame-pointer','-fno-builtin','-DUSE_GP','-DTF_LITE_STATIC_MEMORY',
    '-DTF_LITE_USE_GLOBAL_CMATH_FUNCTIONS','-DTF_LITE_USE_GLOBAL_MIN',
    '-DTF_LITE_USE_GLOBAL_MAX','-DTF_LITE_DISABLE_X86_NEON',
    '-DSYSTEM_UART_A_APB=SYSTEM_UART_0_IO_APB',
    '-DSYSTEM_GPIO_A_APB=SYSTEM_GPIO_0_IO_APB','-DSYSTEM_I2C_A_APB=SYSTEM_I2C_0_IO_APB']
includes=[app,app/'src',app/'src/platform',app/'src/platform/interrupt',
    app/'src/platform/misc',app/'src/platform/tinyml',
    app/'src/tensorflow/third_party/flatbuffers/include',
    app/'src/tensorflow/third_party/gemmlowp',app/'src/tensorflow/third_party/ruy',
    stand/'include',stand/'driver',bsp/'include',bsp/'app']
common += [f'-I{x.as_posix()}' for x in includes]
patterns=['src/*.c','src/*.cc','src/*.cpp','src/*.S','src/model/*.cc',
 'src/platform/*/*.cc','src/platform/*/*.c','src/platform/*/*/*.cc','src/platform/*/*/*.c',
 'src/tests/*.c','src/tests/*.cc','src/tensorflow/lite/*.c','src/tensorflow/lite/c/*.c',
 'src/tensorflow/lite/core/api/*.cc','src/tensorflow/lite/kernels/*.cc',
 'src/tensorflow/lite/kernels/internal/*.cc','src/tensorflow/lite/kernels/internal/optimized/*.cc',
 'src/tensorflow/lite/kernels/internal/reference/*.cc',
 'src/tensorflow/lite/kernels/internal/reference/integer_ops/*.cc',
 'src/tensorflow/lite/micro/*.cc','src/tensorflow/lite/micro/kernels/*.cc',
 'src/tensorflow/lite/micro/memory_planner/*.cc','src/tensorflow/lite/schema/*.cc']
sources=sorted(set(x for pat in patterns for x in app.glob(pat)))
if args.main_source:
    sources=[s for s in sources if s != app/'src/main.cc']+[args.main_source]
sources += [stand/'common'/x for x in ['start.S','trap.S','syscalls.c']]
commands=[]
def compile_one(item):
    i,src=item
    obj=out/f'{i:03d}_{src.stem}.o'
    cpp=src.suffix in ('.cc','.cpp')
    cc=args.toolchain/('riscv-none-elf-g++.exe' if cpp else 'riscv-none-elf-gcc.exe')
    flags=common+(['-std=c++11','-fstrict-aliasing','-fno-rtti','-fno-exceptions',
        '-fno-threadsafe-statics','-fno-use-cxa-atexit'] if cpp else [])
    cmd=[str(cc),*flags,'-c',str(src),'-o',str(obj)]
    commands.append(cmd)
    result=run(cmd)
    (out/(obj.stem+'.log')).write_text(result.stdout+result.stderr,encoding='utf8')
    return result.returncode,obj,src
print('Compiling',len(sources),'official sources',flush=True)
with ThreadPoolExecutor(max_workers=4) as pool:
    results=list(pool.map(compile_one,enumerate(sources)))
(out/'compile_commands.json').write_text(json.dumps(commands,indent=2),encoding='utf8')
failures=[(rc,str(src)) for rc,obj,src in results if rc]
if failures:
    print('COMPILE FAILURES',failures,flush=True);raise SystemExit(1)
elf=out/'tinyml_pdti8.elf'
argsfile=out/'link.rsp'
ld=[*map(lambda r:r[1].as_posix(),results),'-o',elf.as_posix(),
    '-march=rv32im_zicsr_zifencei','-mabi=ilp32','-specs=nosys.specs','-nostartfiles',
    '-Wl,--no-warn-rwx-segments,--gc-sections,-T,'+(bsp/'linker/default.ld').as_posix()+
    ',-Map,'+(out/'tinyml_pdti8.map').as_posix()+',--print-memory-usage',
    (stand/'common/tinyml_lib.a').as_posix(),'-lm','-lc','-lgcc']
argsfile.write_text('\n'.join('"'+str(x).replace('\\','/')+'"' for x in ld),encoding='utf8')
r=run([args.toolchain/'riscv-none-elf-g++.exe','@'+str(argsfile)])
(out/'link.log').write_text(r.stdout+r.stderr,encoding='utf8')
print(r.stdout+r.stderr,flush=True)
if r.returncode: raise SystemExit(r.returncode)
for exe,opts,dest in [('objcopy',['-O','binary',elf],out/'tinyml_pdti8.bin'),
    ('objdump',['-d',elf],out/'tinyml_pdti8.asm'),('size',['-A',elf],out/'size.txt'),
    ('readelf',['-h','-A','-l',elf],out/'elf-info.txt')]:
    r=run([args.toolchain/f'riscv-none-elf-{exe}.exe',*opts,*([dest] if exe=='objcopy' else [])])
    if exe!='objcopy': dest.write_text(r.stdout+r.stderr,encoding='utf8')
    if r.returncode: raise SystemExit(r.returncode)
(out/'sha256.json').write_text(json.dumps({x.name:hashlib.sha256(x.read_bytes()).hexdigest()
    for x in [elf,out/'tinyml_pdti8.bin']},indent=2),encoding='utf8')
print('FIRMWARE BUILD PASS',elf,flush=True)
