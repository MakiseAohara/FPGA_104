"""Run operator-only smoke recording, wait for full exit, open formal panel."""
import argparse
import csv
import datetime as dt
import json
from pathlib import Path
import subprocess
import sys

HERE=Path(__file__).resolve().parent
PS=r'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'
M15='74E205F84613F23C1DD8040E2CF31F032BBF524D3ED81022DE551D998613AF40'


def main():
    parser=argparse.ArgumentParser()
    parser.add_argument('--load-receipt',type=Path,required=True)
    parser.add_argument('--out',type=Path,default=HERE/'manual_smoke')
    args=parser.parse_args()
    args.out=args.out.resolve()
    loaded=json.loads(args.load_receipt.read_text(encoding='utf-8'))
    assert loaded['load_completed'] and loaded['port_closed'] and loaded['bitstream_sha256']==M15 and loaded['firmware_crc32']=='B7CCB8D0'
    args.out.mkdir(parents=True,exist_ok=True)
    assert not (args.out/'log_v27_gate.log').exists(),'Existing smoke record protected'
    with (args.out/'panel_stdout.log').open('xb') as stream:
        smoke=subprocess.Popen([PS,'-NoProfile','-STA','-ExecutionPolicy','Bypass','-File',
              str(HERE/'manual_smoke_panel.ps1'),'-Evidence',str(args.out)],stdout=stream,stderr=subprocess.STDOUT,
              creationflags=subprocess.CREATE_NO_WINDOW)
        print('OPERATOR_SMOKE_PANEL_OPENED',smoke.pid,flush=True)
        code=smoke.wait()
    print('OPERATOR_SMOKE_FULLY_EXITED',smoke.pid,'exit',code,flush=True)
    if code:
        print('Smoke was saved or interrupted without the complete manual sequence; MERGE15 retained. No automatic rollback.',flush=True)
        return code
    result=json.loads((args.out/'manual_smoke_result.json').read_text(encoding='utf-8'))
    assert result['operator_manual_sequence_complete'] and result['smoke_recorder_exited'] and not result['simulation_only']
    with (args.out/'manual_events_raw.csv').open(encoding='utf-8',newline='') as stream:
        events=list(csv.DictReader(stream))
    expected=['EMPTY_CONFIRMED','ENTER','ALARM_CONFIRMED','LEAVE','RELEASE_CONFIRMED']
    index=0
    for row in events:
        if index<len(expected) and row['event']==expected[index] and row['source'] in ('human_key','human_button'):
            index+=1
    assert index==5,'Manual sequence not present in saved operator events'
    result.update(bitstream_sha256=M15,firmware_crc32='B7CCB8D0',rollback_required=False,
                  smoke_panel_pid=smoke.pid,smoke_panel_exit_code=code,truth_source='actual operator inputs only',
                  load_receipt=str(args.load_receipt),smoke_directory=str(args.out))
    (HERE/'board_ready.json').write_text(json.dumps(result,ensure_ascii=False,indent=2)+'\n',encoding='utf-8',newline='\n')
    with (HERE/'formal_panel_stdout.log').open('xb') as stream:
        formal=subprocess.Popen([PS,'-NoProfile','-STA','-ExecutionPolicy','Bypass','-File',str(HERE/'manual_label_panel.ps1')],
                 stdout=stream,stderr=subprocess.STDOUT,creationflags=subprocess.CREATE_NO_WINDOW)
    transition=dict(smoke_recorder_exited=True,smoke_panel_exit_code=code,formal_panel_pid=formal.pid,
                    formal_opened_wall=dt.datetime.now(dt.timezone(dt.timedelta(hours=8))).isoformat(timespec='milliseconds'),
                    serial_overlap=False,formal_start='operator must click Start; no automatic formal T0')
    (HERE/'manual_flow_transition.json').write_text(json.dumps(transition,indent=2)+'\n',encoding='utf-8',newline='\n')
    print('FORMAL_PANEL_OPENED',formal.pid,transition['formal_opened_wall'],flush=True)
    return 0


if __name__=='__main__': raise SystemExit(main())
