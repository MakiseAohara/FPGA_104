
"""build_wbtest.py — 编 WB 扫描固件（6 组增益轮换，每 15 s）。"""
import argparse, hashlib, json, shutil, subprocess, sys, zlib
from pathlib import Path
HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
ap = argparse.ArgumentParser()
ap.add_argument('--project', type=Path, required=True)
ap.add_argument('--out', type=Path, required=True)
ap.add_argument('--toolchain', type=Path, default=Path(r'D:\riscv\xpack-riscv-none-elf-gcc-15.2.0-1\bin'))
a = ap.parse_args()
stage = HERE / '_stage_wbtest'
stage.mkdir(exist_ok=True)
shutil.copy2(HERE / 'main_live292_wbtest.cc', stage / 'main_live292_wbtest.cc')
for h in ('preprocess_core.h', 'ae_core.h', 'cam_ctrl_core.h', 'input_contract.h'):
    shutil.copy2(HERE / h, stage / h)
entry = stage / 'main_wbtest_day.cc'
entry.write_text('#define CAM_PRESET DAY\n#define WB_TESTCYCLE 1\n#include "main_live292_wbtest.cc"\n', encoding='ascii')
cmd = [sys.executable, str(ROOT / 'sw/tinyml_live/build_tinyml_firmware.py'),
       '--project', str(a.project), '--toolchain', str(a.toolchain),
       '--out', str(a.out), '--main-source', str(entry)]
r = subprocess.run(cmd, capture_output=True, timeout=900)
log = (r.stdout or b'') + (r.stderr or b'')
a.out.mkdir(parents=True, exist_ok=True)
(a.out / 'build_wbtest.log').write_bytes(log)
print(log.decode(errors='replace')[-500:])
if r.returncode: raise SystemExit(r.returncode)
data = (a.out / 'tinyml_pdti8.bin').read_bytes()
print(json.dumps(dict(bytes=len(data), crc32=f'{zlib.crc32(data)&0xFFFFFFFF:08X}'), indent=2))
print('BUILD PASS')
