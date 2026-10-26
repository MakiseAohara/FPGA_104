import argparse,importlib.util,json,sys,threading,time
from pathlib import Path
sys.dont_write_bytecode=True
p=argparse.ArgumentParser();p.add_argument('--out',type=Path,required=True);p.add_argument('--stop',type=Path,required=True);p.add_argument('--seconds',type=float,default=900);a=p.parse_args()
source=Path(__file__).parent/'FPGA_104-main/evidence/v22_gate/capture_v22.py'
s=importlib.util.spec_from_file_location('cap',source);m=importlib.util.module_from_spec(s);s.loader.exec_module(m)
sys.path.append(r'D:\Efinity\2026.1\python311\Lib\site-packages')
import serial
a.out.mkdir(parents=True,exist_ok=True)
cap=m.Capture(a.out,resume=(a.out/'log_v22_gate.log').exists());reader=None;thread=None
try:
    cap.log('### WHITE_BALANCE_OBSERVE_START no_flash=1 no_camera_writes=1')
    reader=m.Reader(m.port_open(serial,'COM15'),cap)
    thread=threading.Thread(target=m.pump,args=(reader,argparse.Namespace(port='COM15'),serial),daemon=True);thread.start()
    end=time.monotonic()+a.seconds
    while time.monotonic()<end and not a.stop.exists() and not cap.stop.wait(.2):pass
finally:
    cap.stop.set()
    if thread:thread.join(3)
    if reader:reader.port.close()
    cap.log('### WHITE_BALANCE_OBSERVE_END lines=%d gaps=%d reconnects=%d'%(cap.lines,cap.gaps,cap.reconnects));cap.fh.close()
    (a.out/'serial_status.json').write_text(json.dumps({'serial_lines':cap.lines,'gaps':cap.gaps,'reconnects':cap.reconnects,'live_boots':cap.boots,'last_device_ms':cap.last_dec},indent=2)+'\n',encoding='utf-8')
