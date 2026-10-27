"""Read-only v27 asset identity and serial availability check; never flashes."""
import argparse
import datetime as dt
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import zlib

ROOT = Path(__file__).resolve().parents[2]
M15 = '74E205F84613F23C1DD8040E2CF31F032BBF524D3ED81022DE551D998613AF40'
M14 = 'E399F99067E6544262315607B27FC3DD2394F37FD245F909DEE1EBA8A8B41FE8'
FW = 'BEF15238095C194D4A734BD9F40ED22A0BA6361F325CEB6395AAF51AF9E9828C'


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--merge15', type=Path, default=ROOT/'evidence/v27_rtl_ir/v7_MERGE15.bit')
    parser.add_argument('--merge14', type=Path, default=Path(r'C:\Users\Makise Aohara\Documents\deepseek-harness\default-workspace\evidence\v22_gate\v7_MERGE14.bit'))
    parser.add_argument('--firmware', type=Path, default=ROOT/'evidence/v26_gate/tinyml_pdti8_v26.bin')
    parser.add_argument('--probe-port', action='store_true')
    parser.add_argument('--out', type=Path, default=Path(__file__).with_name('preflight.json'))
    args = parser.parse_args()
    assets = {}
    for key, path, expected in [('merge15',args.merge15,M15),('merge14_fallback',args.merge14,M14),('firmware',args.firmware,FW)]:
        item = dict(path=str(path.resolve()), exists=path.is_file(), expected_sha256=expected)
        if path.is_file():
            data = path.read_bytes()
            item.update(bytes=len(data), sha256=hashlib.sha256(data).hexdigest().upper())
            item['matches_expected'] = item['sha256'] == expected
            if key == 'firmware':
                item['crc32'] = f'{zlib.crc32(data):08X}'
                item['matches_expected'] &= item['crc32']=='B7CCB8D0' and len(data)==477722
        else:
            item['matches_expected'] = False
        assets[key] = item
    result = dict(wall=dt.datetime.now(dt.timezone(dt.timedelta(hours=8))).isoformat(timespec='milliseconds'),
                  repository_head=subprocess.check_output(['git','rev-parse','HEAD'],cwd=ROOT,text=True).strip(),
                  assets=assets, hardware_modified=False, flash_performed=False,
                  smoke_checks={name: None for name in ['hdmi_osd','enter_alarm_leave_release','dec_and_camera_fps','empty_30s_no_alarm']},
                  formal_capture_performed=False, phone_video_received=False)
    if args.probe_port:
        sys.path.append(r'D:\Efinity\2026.1\python311\Lib\site-packages')
        import serial
        from serial.tools import list_ports
        result['serial_ports'] = [p.device for p in list_ports.comports()]
        port = serial.Serial(port=None, baudrate=115200, timeout=1)
        port.dtr = port.rts = False
        port.port = 'COM15'
        try:
            port.open()
            result['serial_probe'] = dict(port='COM15', opened=True, duration_s=1, bytes_received=len(port.read(4096)), receive_only=True)
        except Exception as exc:
            result['serial_probe'] = dict(port='COM15', opened=False, error=repr(exc), receive_only=True)
        finally:
            port.close()
    result['ready_to_flash'] = all(asset['matches_expected'] for asset in assets.values())
    result['blockers'] = [key+' missing or identity mismatch' for key,value in assets.items() if not value['matches_expected']]
    args.out.write_text(json.dumps(result, ensure_ascii=False, indent=2)+'\n', encoding='utf-8')
    print(json.dumps(result, ensure_ascii=False))
    return 0 if result['ready_to_flash'] else 2


if __name__ == '__main__':
    raise SystemExit(main())
