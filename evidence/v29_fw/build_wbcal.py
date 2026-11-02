
"""build_wbcal.py — 用 WB_CAL=1 重编 lpfix：开机自动标定白平衡（针对当前光照）。"""
import argparse, hashlib, json, shutil, subprocess, sys, zlib
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
ap = argparse.ArgumentParser()
ap.add_argument('--project', type=Path, required=True)
ap.add_argument('--out', type=Path, required=True)
ap.add_argument('--toolchain', type=Path, default=Path(r'D:\riscv\xpack-riscv-none-elf-gcc-15.2.0-1\bin'))
a = ap.parse_args()

stage = HERE / '_stage_wbcal'
stage.mkdir(exist_ok=True)
shutil.copy2(HERE / 'main_live292_lpfix.cc', stage / 'main_live292_lpfix.cc')
for h in ('preprocess_core.h', 'ae_core.h', 'cam_ctrl_core.h', 'input_contract.h'):
    shutil.copy2(HERE / h, stage / h)
entry = stage / 'main_wbcal_day.cc'
entry.write_text('#define CAM_PRESET DAY\n#define WB_CAL 1\n#include "main_live292_lpfix.cc"\n', encoding='ascii')

cmd = [sys.executable, str(ROOT / 'sw/tinyml_live/build_tinyml_firmware.py'),
       '--project', str(a.project), '--toolchain', str(a.toolchain),
       '--out', str(a.out), '--main-source', str(entry)]
r = subprocess.run(cmd, capture_output=True, timeout=900)
log = (r.stdout or b'') + (r.stderr or b'')
a.out.mkdir(parents=True, exist_ok=True)
(a.out / 'build_wbcal.log').write_bytes(log)
print(log.decode(errors='replace')[-600:])
if r.returncode:
    raise SystemExit(r.returncode)
data = (a.out / 'tinyml_pdti8.bin').read_bytes()
print(json.dumps(dict(bytes=len(data), crc32=f'{zlib.crc32(data)&0xFFFFFFFF:08X}',
                      sha256=hashlib.sha256(data).hexdigest().upper()), indent=2))
print('BUILD PASS')
