"""Load pinned MERGE15 + v26 once. Host errors do not trigger a rollback."""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import sys
import time
import traceback
import zlib

sys.dont_write_bytecode=True
HERE=Path(__file__).resolve().parent
spec=importlib.util.spec_from_file_location('loader_support',HERE/'run_merge15_smoke.py')
support=importlib.util.module_from_spec(spec)
spec.loader.exec_module(support)
loader=support.loader


def main():
    parser=argparse.ArgumentParser()
    parser.add_argument('--out',type=Path,required=True)
    args=parser.parse_args()
    args.bit=support.ROOT/'evidence/v27_rtl_ir/v7_MERGE15.bit'
    args.image=support.ROOT/'evidence/v26_gate/tinyml_pdti8_v26.bin'
    args.flash=Path(r'C:\Users\Makise Aohara\Documents\Codex\2026-10-15\https-github-com-makiseaohara-fpga-104\outputs\fpga_onboard_verified_20261020\tools\flash_vendor.ps1')
    args.efinity=Path(r'D:\Efinity\2026.1')
    args.port='COM15'
    data=args.image.read_bytes()
    assert len(data)==477722 and zlib.crc32(data)==0xB7CCB8D0 and hashlib.sha256(data).hexdigest().upper()==support.FW
    assert hashlib.sha256(args.bit.read_bytes()).hexdigest().upper()==support.M15
    sys.path.append(str(args.efinity/'python311/Lib/site-packages'))
    import serial
    cap=support.make_capture(args.out,'log_merge15_load.log')
    reader=None
    receipt=dict(started_wall=loader.wall(),bitstream_sha256=support.M15,firmware_crc32='B7CCB8D0',
                 firmware_sha256=support.FW,firmware_bytes=len(data),automatic_rollback=False,
                 firmware_modified=False,camera_commands_sent=False,reset_after_upload=False)
    error=None
    try:
        loader.BIT_SHA=support.M15
        print('MERGE15_AND_V26_PINNED; LOADING',receipt['started_wall'],flush=True)
        reader=loader.flash_and_upload(args,cap,serial,data,1)
        deadline=time.monotonic()+3
        while time.monotonic()<deadline: reader.next_line()
        receipt.update(load_completed=True,board_crc_pass=True,boot_lines=cap.boots,dec_rows_observed=cap.dec_count)
    except Exception as exc:
        error=repr(exc)
        receipt.update(load_completed=False,error=error,error_traceback=traceback.format_exc())
        print('HOST_LOAD_ERROR_NO_ROLLBACK',error,flush=True)
    finally:
        support.close_capture(cap,reader)
        receipt.update(ended_wall=loader.wall(),port_closed=True)
        support.save(args.out/'load_receipt.json',receipt)
    print(json.dumps(receipt,ensure_ascii=False),flush=True)
    return 1 if error else 0


if __name__=='__main__': raise SystemExit(main())
