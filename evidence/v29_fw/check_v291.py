"""v29.1 firmware self-check: embedded model bytes + boot-line strings."""
from pathlib import Path
import json, re, sys

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
tflite = (ROOT / 'evidence/v29_model/v29_person_96_int8.tflite').read_bytes()
old_cc = Path(r'D:\FPGA\codex20\official-tinyml\tinyml_hello_world\Ti60F225_tinyml_hello_world\embedded_sw\SapphireSoc\software\standalone\tinyml_pdti8\src\model\mobilenetv1_person_detect_model_data.cc').read_text(encoding='utf-8', errors='replace')
old_bytes = bytes(int(x, 16) for x in re.findall(r'0x([0-9a-fA-F]{2})', old_cc))
old_head = old_bytes[:32]
identities = json.loads((HERE / 'firmware_identities_v291.json').read_text(encoding='utf-8'))
checks = []
ok = True
for name, info in identities.items():
    data = (HERE / info['file']).read_bytes()
    has_model = tflite in data
    has_old = old_head in data
    strings = {
        'MMT_WB_INIT': b'MMT_WB_INIT' in data,
        'IR_SOLO_ON=%d': b'IR_SOLO_ON=%d' in data,
        'cause=%s': b'cause=%s' in data,
        'v29.1': b'v29.1' in data,
    }
    if name == 'DAYCAL':
        strings['MMT_WB r=%d'] = b'MMT_WB r=%d' in data
        strings['MMT_WB_APPLY'] = b'MMT_WB_APPLY' in data
    row_ok = has_model and not has_old and all(strings.values())
    ok = ok and row_ok
    checks.append(dict(file=info['file'], bytes=len(data), crc32=info['crc32'],
                       embedded_model=has_model, old_model_present=has_old, strings=strings, pass_=row_ok))
    print(name, json.dumps(checks[-1], ensure_ascii=False))
print('MODEL_BYTES', len(tflite), 'OLD_HEAD', old_head.hex())
(HERE / 'selfcheck_v291.json').write_text(json.dumps(dict(model_bytes=len(tflite), checks=checks), indent=2) + '\n', encoding='utf-8')
print('SELFCHECK', 'PASS' if ok else 'FAIL')
sys.exit(0 if ok else 1)
