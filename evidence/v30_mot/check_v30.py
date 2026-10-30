"""v30 firmware self-check: model bytes, MOT strings, version markers.
用法: py -3 check_v30.py [--bin path/to/tinyml_pdti8.bin]
"""
from pathlib import Path
import argparse, hashlib, json, re, sys, zlib

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
ap = argparse.ArgumentParser()
ap.add_argument('--bin', type=Path, default=Path(r'D:\v30_build\out_v30c\tinyml_pdti8.bin'))
a = ap.parse_args()
data = a.bin.read_bytes()
tflite = (ROOT / 'evidence/v29_model/v29_person_96_int8.tflite').read_bytes()
old_cc = Path(r'D:\v30_build\project\embedded_sw\SapphireSoc\software\standalone\tinyml_pdti8\src\model/mobilenetv1_person_detect_model_data.cc').read_text(encoding='utf-8', errors='replace')
old_head = bytes(int(x, 16) for x in re.findall(r'0x([0-9a-fA-F]{2})', old_cc))[:32]

strings = ['MMT_MOT_CFG', 'MMT_TRK', 'MMT_MOT ', 'MMT_PREWARN', 'MMT_PREDLEAD',
           'MMT_FUSION', 'MMT_LIVE_BOOT', 'MMT_ALARM']
res = {
    'file': str(a.bin), 'bytes': len(data),
    'crc32': format(zlib.crc32(data) & 0xffffffff, '08X'),
    'sha256': hashlib.sha256(data).hexdigest().upper(),
    'embedded_model': tflite in data,
    'old_model_present': old_head in data,
    'strings': {s: (s.encode() in data) for s in strings},
}
ok = res['embedded_model'] and not res['old_model_present'] and all(res['strings'].values())
res['pass'] = ok
(HERE / 'firmware_identity_v30.json').write_text(json.dumps(
    {k: res[k] for k in ('bytes', 'crc32', 'sha256')} | {'preset': 'DAY'}, indent=2) + '\n', encoding='utf-8')
(HERE / 'selfcheck_v30.json').write_text(json.dumps(res, indent=2) + '\n', encoding='utf-8')
print(json.dumps(res, indent=2))
print('SELFCHECK', 'PASS' if ok else 'FAIL')
sys.exit(0 if ok else 1)
