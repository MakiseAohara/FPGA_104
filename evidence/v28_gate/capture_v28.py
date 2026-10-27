"""Load pinned v28, then receive 1800 seconds; no manual labels or truth inference."""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import re
import sys
import threading
import time
import traceback
import zlib

sys.dont_write_bytecode=True
HERE=Path(__file__).resolve().parent
ROOT=HERE.parents[1]
spec=importlib.util.spec_from_file_location('existing_loader',ROOT/'evidence/v26_gate/capture_v26.py')
loader=importlib.util.module_from_spec(spec);spec.loader.exec_module(loader)
loader.publish_state=lambda cap:None
M15='74E205F84613F23C1DD8040E2CF31F032BBF524D3ED81022DE551D998613AF40'
THUMB=re.compile(r'^MMT_THUMB t=(\d+) f=(\d+) alarm=([01]) p=(-?\d+) ([0-9a-fA-F]{4608})$')


def save(path,value):
    text=json.dumps(value,ensure_ascii=False,indent=2)+'\n'
    for attempt in range(5):
        try:path.write_text(text,encoding='utf-8',newline='\n');return
        except PermissionError:
            if attempt==4:raise
            time.sleep(.02*(attempt+1))


class Capture(loader.Capture):
    def __init__(self,out):
        super().__init__(out)
        self.fh.close()
        (out/'log_v26_gate.log').rename(out/'log_v28_gate.log')
        self.fh=(out/'log_v28_gate.log').open('a',encoding='utf-8',newline='\n')
        self.thumbs=self.invalid_thumbs=0
    def log(self,text,serial_line=False):
        super().log(text,serial_line)
        if serial_line and text.startswith('MMT_THUMB '):
            if THUMB.fullmatch(text):self.thumbs+=1
            else:self.invalid_thumbs+=1


def receive(reader,cap,serial,port_name):
    while not cap.stop.is_set():
        try:reader.next_line()
        except Exception as exc:
            cap.log('### RECONNECT_TRY error='+repr(exc))
            if reader.buf:
                cap.log('### PARTIAL_LINE_HEX '+reader.buf.hex());reader.buf=b''
            try:reader.port.close()
            except Exception:pass
            while not cap.stop.is_set():
                try:
                    reader.port=loader.port_open(serial,port_name)
                    cap.reconnects+=1
                    cap.log(f'### RECONNECTED count={cap.reconnects} no_reflash=1')
                    break
                except Exception:
                    cap.gap_check();cap.stop.wait(.5)


def main():
    parser=argparse.ArgumentParser()
    parser.add_argument('--seconds',type=float,default=1800)
    parser.add_argument('--port',default='COM15')
    parser.add_argument('--max-attempts',type=int,choices=[1,2,3],default=3)
    args=parser.parse_args()
    args.out=HERE
    args.bit=ROOT/'evidence/v27_rtl_ir/v7_MERGE15.bit'
    args.image=ROOT/'evidence/v28_fw/tinyml_pdti8_v28.bin'
    args.flash=Path(r'C:\Users\Makise Aohara\Documents\Codex\2026-10-15\https-github-com-makiseaohara-fpga-104\outputs\fpga_onboard_verified_20261020\tools\flash_vendor.ps1')
    args.efinity=Path(r'D:\Efinity\2026.1')
    identity=json.loads((ROOT/'evidence/v28_fw/manifest.json').read_text(encoding='utf-8'))['firmware']
    data=args.image.read_bytes()
    assert len(data)==identity['bytes'] and f'{zlib.crc32(data):08X}'==identity['crc32'] and hashlib.sha256(data).hexdigest().upper()==identity['sha256']
    assert hashlib.sha256(args.bit.read_bytes()).hexdigest().upper()==M15
    loader.CRC=identity['crc32'];loader.SHA=identity['sha256'];loader.BIT_SHA=M15
    args.out.mkdir(parents=True,exist_ok=True)
    cap=Capture(args.out);reader=thread=None
    metadata=dict(started_wall=loader.wall(),firmware_file=args.image.name,firmware_bytes=len(data),
        firmware_crc32=identity['crc32'],firmware_sha256=identity['sha256'],bitstream_file=args.bit.name,
        bitstream_sha256=M15,mode='free_movement_v28',requested_seconds=args.seconds,port=args.port,baudrate=115200,
        firmware_modified_during_capture=False,exposure_modified=False,camera_commands_sent=False,
        reset_after_firmware_upload=False,automatic_action_events=False,manual_annotations_requested=False,
        action_prompts=False,truth_source='Claude reviews exported thumbnails; no labels inferred by the capture program')
    attempts=[];error=None
    try:
        cap.log('### CAPTURE_AND_LOAD_START free_movement=1 operator_labels=0')
        sys.path.append(str(args.efinity/'python311/Lib/site-packages'))
        import serial
        for attempt in range(1,args.max_attempts+1):
            record=dict(attempt=attempt,started_wall=loader.wall());attempts.append(record)
            try:
                reader=loader.flash_and_upload(args,cap,serial,data,attempt)
                record.update(load_completed=True,ended_wall=loader.wall());break
            except Exception as exc:
                record.update(load_completed=False,error=repr(exc),ended_wall=loader.wall())
                cap.log('### LOAD_ERROR '+repr(exc));print('LOAD_ERROR',attempt,repr(exc),flush=True)
                save(HERE/'attempts.json',attempts)
                if isinstance(exc,loader.ActiveProgrammingError) or attempt==args.max_attempts:raise
                time.sleep(1)
        metadata['observation_started_wall']=loader.wall()
        cap.t0=metadata['observation_started_wall'];cap.phase='FREE_MOVEMENT'
        cap.log('### OBSERVATION_START seconds=%s no_action_prompts=1 no_manual_labels=1'%args.seconds)
        started=time.monotonic()
        thread=threading.Thread(target=receive,args=(reader,cap,serial,args.port),daemon=True)
        thread.start()
        print('V28_OBSERVATION_STARTED',cap.t0,'seconds',args.seconds,flush=True)
        next_progress=started
        while time.monotonic()-started<args.seconds:
            now=time.monotonic()
            if now>=next_progress:
                progress=dict(wall=loader.wall(),elapsed_s=round(now-started,3),remaining_s=round(max(0,args.seconds-(now-started)),3),
                    dec=cap.dec_count,thumbs=cap.thumbs,invalid_thumbs=cap.invalid_thumbs,gaps=cap.gaps,
                    reconnects=cap.reconnects,device_ms_latest=cap.last_dec)
                try:save(HERE/'run_progress.json',progress)
                except OSError as exc:cap.log('### HOST_PROGRESS_WRITE_ERROR '+repr(exc))
                print('PROGRESS',json.dumps(progress),flush=True);next_progress=now+30
            cap.stop.wait(min(.2,max(0,args.seconds-(time.monotonic()-started))))
        metadata.update(observation_ended_wall=loader.wall(),observation_completed=True,observation_elapsed_s=round(time.monotonic()-started,3))
        cap.log('### OBSERVATION_END')
    except Exception as exc:
        error=repr(exc);metadata['error_traceback']=traceback.format_exc()
        cap.log('### ACQUISITION_ERROR '+error);print(traceback.format_exc(),flush=True)
    finally:
        cap.stop.set()
        if thread:thread.join(timeout=3)
        if reader:
            if reader.buf:cap.log('### FINAL_PARTIAL_LINE_HEX '+reader.buf.hex())
            reader.port.close()
        metadata.update(ended_wall=loader.wall(),acquisition_error=error,dec_records=cap.dec_count,
            thumbnail_lines=cap.thumbs,invalid_thumbnail_lines=cap.invalid_thumbs,gaps=cap.gaps,reconnects=cap.reconnects,
            serial_lines=cap.lines,port_closed=True,boot_lines=cap.boots)
        cap.log(f'### CAPTURE_END dec={cap.dec_count} thumbs={cap.thumbs} gaps={cap.gaps} reconnects={cap.reconnects} error={error}')
        cap.fh.close();cap.uart_fh.close()
        save(HERE/'run_metadata.json',metadata);save(HERE/'attempts.json',attempts)
    return 1 if error else 0


if __name__=='__main__':raise SystemExit(main())
