"""v29.2 build: NIGHT, DAY, and DAY+WB_CAL (calibration) from the same sources."""
from pathlib import Path
import hashlib, json, shutil, subprocess, sys, zlib

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
PROJECT = Path(r'D:\v7work\tiny_proj')
WORK = Path(r'D:\v292_build')
clone = WORK / 'project'
relative = Path('embedded_sw/SapphireSoc/software/standalone')
for name in ('common', 'include', 'driver', 'tinyml_pdti8'):
    if (PROJECT / relative / name).exists():
        shutil.copytree(PROJECT / relative / name, clone / relative / name, dirs_exist_ok=True)
shutil.copytree(PROJECT / 'embedded_sw/SapphireSoc/bsp', clone / 'embedded_sw/SapphireSoc/bsp', dirs_exist_ok=True)
model = clone / relative / 'tinyml_pdti8/src/model'
# v29.2 uses the SECOND-round (day-calibrated) generator under evidence/v29_model/,
# which is byte-identical to evidence/v29_model/v29_person_96_int8.tflite.
# evidence/v29_fw/generator/ still holds the round-1 model and must NOT be used.
MODEL_SRC = ROOT / 'evidence/v29_model/generator'
for suffix in ('cc', 'h'):
    shutil.copy2(MODEL_SRC / ('v29_person_96_int8_model_data.' + suffix), model)

TARGETS = [
    ('NIGHT', HERE / 'main_live292.cc'),
    ('DAY', HERE / 'main_live292_day.cc'),
]
identities = {}
only = sys.argv[1].upper() if len(sys.argv) > 1 else None
for name, source in TARGETS:
    if only and name != only:
        continue
    out = WORK / name.lower()
    command = [sys.executable, str(ROOT / 'sw/tinyml_live/build_tinyml_firmware.py'),
               '--project', str(clone), '--toolchain', r'D:\riscv\xpack-riscv-none-elf-gcc-15.2.0-1\bin',
               '--out', str(out), '--main-source', str(source)]
    result = subprocess.run(command, capture_output=True, timeout=600)
    (HERE / (name.lower() + '_build.log')).write_bytes(result.stdout + result.stderr)
    print(name, result.returncode, (result.stdout + result.stderr).decode(errors='replace')[-1200:], flush=True)
    if result.returncode:
        raise SystemExit(result.returncode)
    fname = 'tinyml_pdti8_v292_' + name.lower()
    for suffix in ('bin', 'elf'):
        shutil.copy2(out / ('tinyml_pdti8.' + suffix), HERE / (fname + '.' + suffix))
    data = (HERE / (fname + '.bin')).read_bytes()
    identities[name] = dict(file=fname + '.bin', bytes=len(data),
                            crc32=f'{zlib.crc32(data):08X}',
                            sha256=hashlib.sha256(data).hexdigest().upper(),
                            model_sha256=hashlib.sha256((ROOT / 'evidence/v29_model/v29_person_96_int8.tflite').read_bytes()).hexdigest().upper(),
                            camera=dict(vts=1500, exp20=47824, gc=129,
                                        gf=63 if name == 'NIGHT' else 42))
    for info in ('compile_commands.json', 'link.log', 'size.txt', 'elf-info.txt'):
        folder = HERE / name.lower()
        folder.mkdir(exist_ok=True)
        shutil.copy2(out / info, folder / info)
(HERE / 'firmware_identities_v292.json').write_text(json.dumps(identities, indent=2) + '\n', encoding='utf-8')
print(json.dumps(identities), flush=True)
