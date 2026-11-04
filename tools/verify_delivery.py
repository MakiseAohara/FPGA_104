"""Read-only delivery checks, without board access or third-party packages."""
import hashlib
import json
from pathlib import Path
import sys
import xml.etree.ElementTree as ET
import zlib

ROOT = Path(__file__).resolve().parents[1]


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def check():
    current = ROOT / 'project/current'
    manifest = json.loads((current / 'SOURCE_MANIFEST.json').read_text(encoding='utf-8'))
    for entry in manifest['files']:
        path = current / entry['path']
        if not path.resolve().is_relative_to(current.resolve()):
            raise ValueError('Invalid manifest path: ' + entry['path'])
        assert path.stat().st_size == entry['bytes'], 'Source size: ' + entry['path']
        assert digest(path) == entry['sha256'], 'Source hash: ' + entry['path']
    license_path = current / 'third_party/TinyML_LICENSE.txt'
    assert digest(license_path) == manifest['tinyml_license_sha256'], 'TinyML license hash'
    identity = json.loads((ROOT / 'firmware/firmware_identity.json').read_text(encoding='utf-8'))
    data = (ROOT / 'firmware/tinyml_pdti8.bin').read_bytes()
    assert len(data) == identity['bytes'] == 438506, 'Application size'
    assert f'{zlib.crc32(data) & 0xffffffff:08X}' == identity['crc32'] == 'B42CC161', 'Application CRC'
    assert hashlib.sha256(data).hexdigest().upper() == identity['sha256'], 'Application SHA256'
    assert digest(ROOT / 'firmware/netfix04_rxq2_seed1.bit').upper() == '865458AB2AF51C366AAA2C22DCFA3312F4AB104E90680185BC90F58BDF0E69F5', 'Bitstream SHA256'
    tree = ET.parse(current / 'efinity/ti60f225_oob.xml')
    references = [e.attrib['name'] for e in tree.iter() if e.tag.endswith(('design_file', 'constraint_file')) and 'name' in e.attrib]
    for reference in references:
        assert (current / 'efinity' / reference).is_file(), 'Efinity reference: ' + reference
    for name in ('ti60f225_oob.peri.xml', 'ti60f225_oob.sdc'):
        assert (current / 'efinity' / name).is_file(), 'Efinity interface/constraint: ' + name
    model = 'v29_person_96_int8_model_data.cc'
    sdk = current / 'riscv/embedded_sw/SapphireSoc/software/standalone'
    for relative in ('src/model/' + model, 'src/generator/' + model):
        assert digest(sdk / 'tinyml_pdti8' / relative) == manifest['model_sha256'], 'SDK model: ' + relative
    assert digest(ROOT / 'submission/model/v29_model/generator' / model) == manifest['model_sha256'], 'Repository model'
    assert (sdk / 'common/tinyml_lib.a').is_file(), 'Platform static library'
    return {'passed': True, 'source_files_verified': len(manifest['files']), 'efinity_references_verified': len(references), 'application_crc32': identity['crc32'], 'checks': 'File integrity and project references; no hardware or algorithm accuracy test'}


if __name__ == '__main__':
    try:
        print(json.dumps(check(), ensure_ascii=True, indent=2))
    except (AssertionError, OSError, ValueError, KeyError, ET.ParseError) as exc:
        print(json.dumps({'passed': False, 'error': str(exc)}, ensure_ascii=True), file=sys.stderr)
        raise SystemExit(1)
