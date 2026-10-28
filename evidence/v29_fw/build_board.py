"""Build both presets using isolated copies of the official project sources."""
from pathlib import Path
import hashlib
import json
import shutil
import subprocess
import sys
import zlib

HERE=Path(__file__).resolve().parent
ROOT=HERE.parents[1]
PROJECT=Path(r'D:\FPGA\codex20\official-tinyml\tinyml_hello_world\Ti60F225_tinyml_hello_world')
WORK=ROOT.parent/'v29_production_build'
clone=WORK/'project'
relative=Path('embedded_sw/SapphireSoc/software/standalone')
for name in ('common','include','driver','tinyml_pdti8'):
    if (PROJECT/relative/name).exists():shutil.copytree(PROJECT/relative/name,clone/relative/name,dirs_exist_ok=True)
shutil.copytree(PROJECT/'embedded_sw/SapphireSoc/bsp',clone/'embedded_sw/SapphireSoc/bsp',dirs_exist_ok=True)
model=clone/relative/'tinyml_pdti8/src/model'
for suffix in ('cc','h'):
    shutil.copy2(HERE/'generator'/('v29_person_96_int8_model_data.'+suffix),model)
identities={}
for preset in ('NIGHT','DAY'):
    source=HERE/'main_live29.cc'
    if preset=='DAY':
        source=HERE/'main_live29_day.cc'
        source.write_text('#define CAM_PRESET DAY\n#include "main_live29.cc"\n',encoding='utf-8')
    out=WORK/preset.lower()
    command=[sys.executable,str(ROOT/'sw/tinyml_live/build_tinyml_firmware.py'),
        '--project',str(clone),'--toolchain',r'D:\riscv\xpack-riscv-none-elf-gcc-15.2.0-1\bin',
        '--out',str(out),'--main-source',str(source)]
    result=subprocess.run(command,capture_output=True,timeout=180)
    (HERE/(preset.lower()+'_build.log')).write_bytes(result.stdout+result.stderr)
    print(preset,result.returncode,(result.stdout+result.stderr).decode(errors='replace')[-900:],flush=True)
    if result.returncode:raise SystemExit(result.returncode)
    name='tinyml_pdti8_v29_'+preset.lower()
    for suffix in ('bin','elf'):shutil.copy2(out/('tinyml_pdti8.'+suffix),HERE/(name+'.'+suffix))
    data=(HERE/(name+'.bin')).read_bytes()
    identities[preset]=dict(file=name+'.bin',bytes=len(data),crc32=f'{zlib.crc32(data):08X}',sha256=hashlib.sha256(data).hexdigest().upper(),
        camera=dict(vts=1500,exp20=47824,gc=129,gf=63 if preset=='NIGHT' else 42))
    for info in ('compile_commands.json','link.log','size.txt','elf-info.txt'):
        folder=HERE/preset.lower();folder.mkdir(exist_ok=True);shutil.copy2(out/info,folder/info)
(HERE/'firmware_identities.json').write_text(json.dumps(identities,indent=2)+'\n',encoding='utf-8')
print(json.dumps(identities),flush=True)
