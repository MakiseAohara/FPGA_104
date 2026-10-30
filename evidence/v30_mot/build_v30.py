"""build_v30.py — 从仓库源码重建 v30（多目标跟踪 + 行为预测）固件。

前置：
  - SoC 软件工程树（Ti60F225_tinyml_hello_world）复制到无空格短路径，例如 D:\v30_build\project
  - 模型：evidence/v29_model/generator/v29_person_96_int8_model_data.{cc,h}
        拷到 project/.../tinyml_pdti8/src/model/ 和 .../src/generator/（头文件按 generator/ 路径包含）
  - 工具链：D:\riscv\xpack-riscv-none-elf-gcc-15.2.0-1\bin

用法：
  py -3 build_v30.py --project D:\v30_build\project --out D:\v30_build\out_v30
  py -3 build_v30.py --project ... --out ... --night     # NIGHT 预设（默认 DAY）
"""
import argparse, hashlib, json, shutil, subprocess, sys, zlib
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
ap = argparse.ArgumentParser()
ap.add_argument('--project', type=Path, required=True)
ap.add_argument('--out', type=Path, required=True)
ap.add_argument('--toolchain', type=Path,
                default=Path(r'D:\riscv\xpack-riscv-none-elf-gcc-15.2.0-1\bin'))
ap.add_argument('--night', action='store_true')
a = ap.parse_args()

stage = HERE / '_stage'
stage.mkdir(exist_ok=True)
main = stage / 'main_live30.cc'
shutil.copy2(HERE / 'main_live30.cc', main)
shutil.copy2(HERE / 'mot_core.h', stage / 'mot_core.h')
entry = stage / ('main_live30_day.cc' if not a.night else 'main_live30_night.cc')
entry.write_text('#define CAM_PRESET DAY\n#include "main_live30.cc"\n' if not a.night
                 else '#include "main_live30.cc"\n', encoding='ascii')

cmd = [sys.executable, str(ROOT / 'sw/tinyml_live/build_tinyml_firmware.py'),
       '--project', str(a.project), '--toolchain', str(a.toolchain),
       '--out', str(a.out), '--main-source', str(entry)]
r = subprocess.run(cmd, capture_output=True, timeout=900)
log = r.stdout + r.stderr
(a.out / 'build_v30.log').parent.mkdir(parents=True, exist_ok=True)
(a.out / 'build_v30.log').write_bytes(log)
print(log.decode(errors='replace')[-800:])
if r.returncode:
    raise SystemExit(r.returncode)
data = (a.out / 'tinyml_pdti8.bin').read_bytes()
info = dict(bin=str(a.out / 'tinyml_pdti8.bin'), bytes=len(data),
            crc32=f'{zlib.crc32(data) & 0xFFFFFFFF:08X}',
            sha256=hashlib.sha256(data).hexdigest().upper(),
            preset='NIGHT' if a.night else 'DAY')
(HERE / 'firmware_identity_v30.json').write_text(json.dumps(info, indent=2) + '\n', encoding='utf-8')
print(json.dumps(info))
print('FIRMWARE BUILD PASS')
