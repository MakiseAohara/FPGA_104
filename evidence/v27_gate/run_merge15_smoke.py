"""Load the two pinned artifacts, receive smoke facts, roll back on any failure.

Uses the previously exercised v26 loader without changing its firmware bytes.
No planned human action is logged. The formal capture panel is left unchanged.
"""
import argparse
import csv
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import time
import traceback
import zlib

sys.dont_write_bytecode=True
HERE=Path(__file__).resolve().parent
ROOT=HERE.parents[1]
M15='74E205F84613F23C1DD8040E2CF31F032BBF524D3ED81022DE551D998613AF40'
M14='E399F99067E6544262315607B27FC3DD2394F37FD245F909DEE1EBA8A8B41FE8'
FW='BEF15238095C194D4A734BD9F40ED22A0BA6361F325CEB6395AAF51AF9E9828C'
KV=re.compile(r'\b([A-Za-z_][A-Za-z0-9_]*)=([^\s]+)')
spec=importlib.util.spec_from_file_location('v26_loader',ROOT/'evidence/v26_gate/capture_v26.py')
loader=importlib.util.module_from_spec(spec)
spec.loader.exec_module(loader)


def save(path,data):
    pending=path.with_suffix('.tmp')
    for attempt in range(6):
        try:
            pending.write_text(json.dumps(data,ensure_ascii=False,indent=2)+'\n',encoding='utf-8',newline='\n')
            os.replace(pending,path)
            return True
        except PermissionError:
            if attempt==5:
                if path.name=='smoke_live.json':
                    return False  # Display can keep its prior snapshot until the next publish.
                raise
            time.sleep(0.01*(attempt+1))


class SmokeFacts:
    def __init__(self):
        self.checks=dict.fromkeys(['hdmi_osd','enter_alarm_leave_release','dec_and_camera_fps','empty_30s_no_alarm'])
        self.latest=self.fps=self.irhot=self.body=None
        self.last_operator=''
        self.dec=[]
        self.fps_samples=[]
        self.empty_since=None
        self.empty_samples=0
        self.enter_wall=self.leave_wall=None
        self.alarm_seen=self.release_seen=self.visual_b=False
        self.failure=None
        self.failure_kind=None

    def operator(self,row):
        event=row['event']
        stamp=loader.dt.datetime.fromisoformat(row['wall']).timestamp()
        self.last_operator=f"{event} @ {row['wall']}"
        if event=='HDMI_OK': self.checks['hdmi_osd']=True
        elif event=='ENTER':
            if self.empty_since is not None and self.checks['empty_30s_no_alarm'] is not True:
                self.empty_since=None;self.empty_samples=0
            self.enter_wall=stamp
            if self.checks['enter_alarm_leave_release'] is not True:
                self.leave_wall=None
                self.alarm_seen=self.release_seen=self.visual_b=False
        elif event=='LEAVE': self.leave_wall=stamp
        elif event=='EMPTY_CONFIRMED' and self.checks['empty_30s_no_alarm'] is not True:
            self.empty_since=stamp;self.empty_samples=0
        elif event=='VISUAL_ALARM_RELEASE_OK': self.visual_b=True
        elif event in ('FAIL','STOP'):
            self.failure='Operator reported an abnormality' if event=='FAIL' else 'Operator ended smoke before all four facts were confirmed'
            self.failure_kind='operator_failure' if event=='FAIL' else 'not_confirmed'
        self.refresh_b()

    def refresh_b(self):
        if self.alarm_seen and self.release_seen and self.visual_b:
            self.checks['enter_alarm_leave_release']=True

    def serial(self,text,stamp):
        fields=dict(KV.findall(text))
        if text.startswith('MMT_LP '):
            if 'camfps' in fields:
                self.fps=int(fields['camfps'])
                if self.fps>0: self.fps_samples.append(self.fps)
            if 'body' in fields: self.body=int(fields['body'])
        elif text.startswith('MMT_DEC '):
            value=int(fields['t'])
            if self.latest is not None and value<self.latest:
                self.failure='Device clock moved backwards';self.failure_kind='board_failure';return
            self.latest=value
            alarm=int(fields['alarm_req'])
            self.irhot=int(fields['irhot']) if 'irhot' in fields else None
            self.dec.append((stamp,value,alarm))
            if self.enter_wall is not None and stamp>=self.enter_wall and self.leave_wall is None and alarm==1:
                self.alarm_seen=True
            if self.leave_wall is not None and stamp>=self.leave_wall and self.alarm_seen and alarm==0:
                self.release_seen=True
            if self.empty_since is not None and stamp>=self.empty_since and self.checks['empty_30s_no_alarm'] is not True:
                self.empty_samples+=1
                if alarm:
                    self.checks['empty_30s_no_alarm']=False
                    self.failure='Alarm during operator-confirmed initial empty window';self.failure_kind='board_failure'
                elif stamp-self.empty_since>=30 and self.empty_samples>=20:
                    self.checks['empty_30s_no_alarm']=True
            self.refresh_b()
        elif text.startswith(('MMT_DDR_FAIL','MMT_AI_FAIL','MMT_LOAD_FAIL','MMT_LOADER_READY')):
            self.failure='Unexpected board state: '+text;self.failure_kind='board_failure'
        if len(self.dec)>=20 and self.dec[-1][0]-self.dec[0][0]>=10 and self.fps_samples:
            import statistics
            median=statistics.median(self.fps_samples)
            continuous=max(b[0]-a[0] for a,b in zip(self.dec,self.dec[1:]))<=5
            if continuous and 55<=median<=65: self.checks['dec_and_camera_fps']=True
            elif self.dec[-1][0]-self.dec[0][0]>=30:
                self.checks['dec_and_camera_fps']=False
                self.failure='DEC continuity or observed nonzero camera fps outside smoke criterion';self.failure_kind='board_failure'


def make_capture(out,name):
    out.mkdir(parents=True,exist_ok=True)
    cap=loader.Capture(out)
    cap.fh.close()
    (out/'log_v26_gate.log').rename(out/name)
    cap.fh=(out/name).open('a',encoding='utf-8',newline='\n')
    return cap


def close_capture(cap,reader):
    if reader:
        if reader.buf: cap.log('### FINAL_PARTIAL_LINE_HEX '+reader.buf.hex())
        reader.port.close()
    cap.log(f'### CAPTURE_END lines={cap.lines} gaps={cap.gaps} reconnects={cap.reconnects}')
    cap.fh.close();cap.uart_fh.close()


def main():
    parser=argparse.ArgumentParser()
    parser.add_argument('--smoke-seconds',type=float,default=300)
    parser.add_argument('--port',default='COM15')
    parser.add_argument('--out',type=Path,default=HERE/'smoke')
    parser.add_argument('--rollback-out',type=Path,default=HERE/'rollback_merge14')
    args=parser.parse_args()
    smoke_out=args.out
    args.bit=ROOT/'evidence/v27_rtl_ir/v7_MERGE15.bit'
    args.image=ROOT/'evidence/v26_gate/tinyml_pdti8_v26.bin'
    args.flash=Path(r'C:\Users\Makise Aohara\Documents\Codex\2026-10-15\https-github-com-makiseaohara-fpga-104\outputs\fpga_onboard_verified_20261020\tools\flash_vendor.ps1')
    args.efinity=Path(r'D:\Efinity\2026.1')
    fallback=Path(r'C:\Users\Makise Aohara\Documents\deepseek-harness\default-workspace\evidence\v22_gate\v7_MERGE14.bit')
    data=args.image.read_bytes()
    assert len(data)==477722 and zlib.crc32(data)==0xB7CCB8D0 and hashlib.sha256(data).hexdigest().upper()==FW,'Firmware mismatch before flash'
    assert hashlib.sha256(args.bit.read_bytes()).hexdigest().upper()==M15,'MERGE15 hash mismatch before flash'
    assert hashlib.sha256(fallback.read_bytes()).hexdigest().upper()==M14,'Fallback hash mismatch before flash'
    args.out.mkdir(parents=True,exist_ok=True)
    if (args.out/'operator_events_raw.csv').exists(): raise FileExistsError('Existing smoke run protected')
    event_path=args.out/'operator_events_raw.csv'
    event_path.write_text('event,wall,device_ms_latest,source\n',encoding='utf-8',newline='\n')
    facts=SmokeFacts()
    receipt=dict(started_wall=loader.wall(),bitstream_sha256=M15,firmware_crc32='B7CCB8D0',firmware_sha256=FW,
                 firmware_bytes=len(data),checks=facts.checks,rollback_required=False,load_completed=False,formal_panel_opened=False)
    phase='LOADING'
    ui_deferrals=0
    def publish():
        nonlocal ui_deferrals
        written=save(smoke_out/'smoke_live.json',dict(phase=phase,checks=facts.checks,device_ms=facts.latest,
             camfps=facts.fps,irhot=facts.irhot,body10=facts.body,last_operator_event=facts.last_operator))
        if not written: ui_deferrals+=1
    publish()
    panel=subprocess.Popen([loader.powershell(),'-NoProfile','-STA','-ExecutionPolicy','Bypass','-File',
             str(HERE/'smoke_panel.ps1'),'-Evidence',str(args.out)],env=loader.powershell_env(),creationflags=subprocess.CREATE_NO_WINDOW)
    sys.path.append(str(args.efinity/'python311/Lib/site-packages'))
    import serial
    cap=make_capture(args.out,'log_v27_smoke.log')
    reader=None
    failure=None
    active_programming=False
    flash_started=False
    try:
        panel_deadline=time.monotonic()+8
        while not (args.out/'panel_ready.json').exists():
            if panel.poll() is not None or time.monotonic()>panel_deadline:
                raise RuntimeError('Smoke observation panel did not open; no flash started')
            time.sleep(0.1)
        loader.BIT_SHA=M15
        print('PINNED_ARTIFACTS_VERIFIED; FLASH_MERGE15_START',loader.wall(),flush=True)
        flash_started=True
        reader=loader.flash_and_upload(args,cap,serial,data,1)
        receipt.update(load_completed=True,load_completed_wall=loader.wall(),boot_lines=list(cap.boots))
        smoke_gap_base=cap.gaps
        phase='SMOKE';publish()
        print('SMOKE_ACTIVE',loader.wall(),'operator_panel_pid',panel.pid,flush=True)
        started=time.monotonic();last_publish=0;last_progress=0;processed=0
        while time.monotonic()-started<args.smoke_seconds:
            # Read operator input before each buffered DEC, preserving observed wall times.
            try:
                events=event_path.read_bytes()
            except PermissionError:
                events=b''  # The UI's short append owns the file; read complete rows next iteration.
            if events.endswith(b'\n'):
                rows=list(csv.DictReader(io.StringIO(events.decode('utf-8-sig'))))
                for row in rows[processed:]:
                    facts.operator(row)
                    print('OPERATOR',row['event'],row['wall'],flush=True)
                processed=len(rows)
            if facts.failure: raise RuntimeError(facts.failure)
            line=reader.next_line()
            if line: facts.serial(line,time.time())
            if facts.failure: raise RuntimeError(facts.failure)
            if cap.gaps>smoke_gap_base:
                facts.checks['dec_and_camera_fps']=False
                facts.failure_kind='board_failure'
                raise RuntimeError('UART idle gap >5 s during smoke')
            if facts.dec and time.time()-facts.dec[-1][0]>5:
                facts.checks['dec_and_camera_fps']=False
                facts.failure_kind='board_failure'
                raise RuntimeError('No new DEC for >5 s during smoke')
            if all(value is True for value in facts.checks.values()):
                phase='PASSED';publish();break
            if time.monotonic()-last_publish>0.15: publish();last_publish=time.monotonic()
            if time.monotonic()-last_progress>20:
                print('SMOKE_STATUS',json.dumps(dict(elapsed_s=round(time.monotonic()-started),checks=facts.checks,dec=len(facts.dec),irhot=facts.irhot)),flush=True)
                last_progress=time.monotonic()
        else:
            facts.failure_kind='not_confirmed'
            raise TimeoutError('Smoke window ended without all four independently recorded facts')
    except Exception as exc:
        failure=repr(exc)
        receipt['error_traceback']=traceback.format_exc()
        active_programming=isinstance(exc,loader.ActiveProgrammingError)
        if receipt['load_completed'] and facts.failure_kind is None:
            if isinstance(exc,serial.SerialException):
                facts.failure_kind='smoke_transport_interruption'
                facts.checks['dec_and_camera_fps']=False
            elif isinstance(exc,OSError):
                facts.failure_kind='host_io_error'
            else:
                facts.failure_kind='host_error'
        receipt.update(smoke_error=failure,failure_kind=facts.failure_kind or 'loading_failure',rollback_required=True)
        phase='ROLLBACK';publish()
        print('SMOKE_STOP',failure,flush=True)
    finally:
        close_capture(cap,reader)
    receipt.update(checks=facts.checks,smoke_ended_wall=loader.wall(),dec_rows=len(facts.dec),
                   camera_fps_nonzero=facts.fps_samples,operator_rows=processed if 'processed' in locals() else 0,
                   gaps=cap.gaps,smoke_gaps=cap.gaps-(smoke_gap_base if 'smoke_gap_base' in locals() else cap.gaps),
                   reconnects=cap.reconnects,ui_status_deferrals=ui_deferrals)
    if failure:
        if not flash_started:
            receipt.update(rollback_required=False,rollback_completed=False,rollback_note='No hardware operation was started')
        elif active_programming:
            receipt['rollback_error']='Previous JTAG transaction still active; do not overlap programmers'
        else:
            args.out=args.rollback_out;args.bit=fallback
            rollback_cap=make_capture(args.out,'log_merge14_restore.log')
            rollback_reader=None
            try:
                loader.BIT_SHA=M14
                print('RESTORE_MERGE14_START',loader.wall(),flush=True)
                rollback_reader=loader.flash_and_upload(args,rollback_cap,serial,data,1)
                deadline=time.monotonic()+20
                rows=0
                while time.monotonic()<deadline:
                    text=rollback_reader.next_line()
                    if text and text.startswith('MMT_DEC '): rows+=1
                    if rows>=5: break
                receipt.update(rollback_completed=True,rollback_bitstream_sha256=M14,rollback_firmware_crc32='B7CCB8D0',
                               rollback_ended_wall=loader.wall(),rollback_dec_rows=rows)
                print('RESTORE_MERGE14_DONE',rows,'DEC',flush=True)
            except Exception as exc:
                receipt.update(rollback_completed=False,rollback_error=repr(exc))
                print('RESTORE_MERGE14_ERROR',repr(exc),flush=True)
            finally:
                close_capture(rollback_cap,rollback_reader)
        phase='STOPPED';publish()
        save(HERE/'board_setup.json',receipt)
        return 2
    receipt['rollback_required']=False
    save(HERE/'board_ready.json',receipt)
    save(HERE/'board_setup.json',receipt)
    command=[loader.powershell(),'-NoProfile','-STA','-ExecutionPolicy','Bypass','-File',str(HERE/'manual_label_panel.ps1')]
    formal=subprocess.Popen(command,env=loader.powershell_env(),creationflags=subprocess.CREATE_NO_WINDOW)
    receipt.update(formal_panel_opened=True,formal_panel_pid=formal.pid,formal_panel_opened_wall=loader.wall())
    save(HERE/'board_setup.json',receipt)
    print('FORMAL_PANEL_OPENED',formal.pid,loader.wall(),flush=True)
    return 0


if __name__=='__main__':
    print('RETIRED: automatic smoke judgment and automatic host-error rollback are disabled. '
          'Use load_merge15_once.py, then open_manual_flow.py (operator observations only).',flush=True)
    raise SystemExit(2)
