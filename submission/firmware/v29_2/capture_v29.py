"""Single-owner UART: load, brightness, prompted direction, then free movement."""
import argparse
import csv
import hashlib
import importlib.util
import json
from pathlib import Path
import re
import statistics
import subprocess
import sys
import threading
import time
import zlib

sys.dont_write_bytecode=True
HERE=Path(__file__).resolve().parent;ROOT=HERE.parents[1];OUT=ROOT/'evidence/v29_gate'
spec=importlib.util.spec_from_file_location('continuous',ROOT/'evidence/v28_gate/capture_v28.py')
continuous=importlib.util.module_from_spec(spec);spec.loader.exec_module(continuous);loader=continuous.loader
voice_spec=importlib.util.spec_from_file_location('scene',ROOT/'evidence/v29_scene/capture_scene.py')
scene=importlib.util.module_from_spec(voice_spec);voice_spec.loader.exec_module(scene)
KV=re.compile(r'\b([A-Za-z_][A-Za-z0-9_]*)=([^\s]+)')


class Capture(continuous.Capture):
    def __init__(self,out):
        if (out/'log_v29_gate.log').exists():
            loader.Capture.__init__(self,out,resume=True)
            self.thumbs=self.invalid_thumbs=0
        else:
            super().__init__(out);self.fh.close();(out/'log_v28_gate.log').rename(out/'log_v29_gate.log')
        self.fh.close()
        self.fh=(out/'log_v29_gate.log').open('a',encoding='utf-8',newline='\n')
        self.means=[];self.scores=[];self.camera_errors=[];self.fixed=[]
    def log(self,text,serial_line=False):
        super().log(text,serial_line)
        if not serial_line:return
        f=dict(KV.findall(text))
        if text.startswith('MMT_PP ') and 'mean_sensor' in f:self.means.append(int(f['mean_sensor']))
        if text.startswith('MMT_AI ') and 'p' in f:self.scores.append(int(f['p']))
        if text.startswith('MMT_BRIGHT_ERROR'):self.camera_errors.append(text)
        if text.startswith('MMT_BRIGHT_LOCKED'):self.fixed.append(f)


def main():
    options=argparse.ArgumentParser();options.add_argument('--resume',action='store_true');options=options.parse_args()
    OUT.mkdir(exist_ok=True)
    identity=json.loads((HERE/'firmware_identities.json').read_text(encoding='utf-8'))
    args=argparse.Namespace(out=OUT,port='COM15',bit=ROOT/'evidence/v27_rtl_ir/v7_MERGE15.bit',
        efinity=Path(r'D:\Efinity\2026.1'),
        flash=Path(r'C:\Users\Makise Aohara\Documents\Codex\2026-10-15\https-github-com-makiseaohara-fpga-104\outputs\fpga_onboard_verified_20261020\tools\flash_vendor.ps1'))
    assert hashlib.sha256(args.bit.read_bytes()).hexdigest().upper()==continuous.M15
    sys.path.append(str(args.efinity/'python311/Lib/site-packages'));import serial
    previous=json.loads((OUT/'run_metadata.json').read_text(encoding='utf-8')) if options.resume else {}
    cap=Capture(OUT);reader=thread=None;events=list(previous.get('phases',[]));error=None;selected=previous.get('selected_preset','NIGHT');results={}
    cap.gaps=previous.get('gaps',0);cap.reconnects=previous.get('reconnects',0)
    panel=subprocess.Popen([loader.powershell(),'-NoProfile','-STA','-ExecutionPolicy','Bypass','-File',str(ROOT/'evidence/v29_scene/phase_panel.ps1')],stdin=subprocess.PIPE,text=True,encoding='utf-8',env=loader.powershell_env(),creationflags=subprocess.CREATE_NO_WINDOW)
    def display(title,instruction,status):
        try:panel.stdin.write(json.dumps(dict(title=title,instruction=instruction,status=status),ensure_ascii=False)+'\n');panel.stdin.flush()
        except (OSError,ValueError):pass
    def stop_reader():
        nonlocal reader,thread
        cap.stop.set()
        if thread:thread.join(timeout=3)
        if reader:
            if reader.buf:cap.log('### PARTIAL_LINE_HEX '+reader.buf.hex());reader.buf=b''
            reader.port.close()
        reader=thread=None
    def load(preset):
        nonlocal reader,thread
        cap.stop=threading.Event();args.image=HERE/identity[preset]['file'];data=args.image.read_bytes()
        assert hashlib.sha256(data).hexdigest().upper()==identity[preset]['sha256'] and f'{zlib.crc32(data):08X}'==identity[preset]['crc32']
        loader.CRC=identity[preset]['crc32'];loader.SHA=identity[preset]['sha256'];loader.BIT_SHA=continuous.M15
        reader=loader.flash_and_upload(args,cap,serial,data,1 if preset=='NIGHT' else 2)
        thread=threading.Thread(target=continuous.receive,args=(reader,cap,serial,args.port),daemon=True);thread.start()
    def phase(name,seconds,instruction,brightness=False):
        started=time.monotonic();wall=loader.wall();first_ai=len(cap.scores);first_mean=len(cap.means)
        event=dict(phase=name,start_wall=wall,start_device_ms=cap.last_dec,planned_seconds=seconds,actual_human_truth=False)
        events.append(event);cap.log('### PHASE_START '+name+' requested_protocol_only=1');scene.speak(instruction)
        print('PHASE_START',name,wall,flush=True);last=0
        while time.monotonic()-started<seconds:
            if cap.camera_errors:raise RuntimeError('; '.join(cap.camera_errors))
            if brightness and any(x>130 for x in cap.means[first_mean:]):
                event['brightness_over_130']=True;break
            elapsed=time.monotonic()-started
            if elapsed-last>=5 or last==0:
                display(f'{name}  剩余 {max(0,seconds-elapsed):.0f} 秒',instruction,f'预设 {selected}；GAP={cap.gaps}；重连={cap.reconnects}；阶段提示不是人体真值')
                continuous.save(OUT/'run_progress.json',dict(wall=loader.wall(),phase=name,remaining_s=round(max(0,seconds-elapsed),1),preset=selected,gaps=cap.gaps,reconnects=cap.reconnects,latest_device_ms=cap.last_dec,mean_sensor=cap.means[-1] if cap.means else None))
                last=elapsed or .001
            time.sleep(.1)
        scores=cap.scores[first_ai:];means=cap.means[first_mean:]
        event.update(end_wall=loader.wall(),end_device_ms=cap.last_dec,elapsed_seconds=round(time.monotonic()-started,3),
            ai_samples=len(scores),p_median=statistics.median(scores) if scores else None,
            mean_sensor_median=statistics.median(means) if means else None,mean_sensor_max=max(means) if means else None)
        cap.log('### PHASE_END '+name);continuous.save(OUT/'phase_events.json',events);return event
    try:
        if options.resume:
            cap.log('### RESUME_CAPTURE no_flash=1 no_reset=1 prior_error='+str(previous.get('error')))
            reader=loader.Reader(loader.port_open(serial,args.port),cap)
            thread=threading.Thread(target=continuous.receive,args=(reader,cap,serial,args.port),daemon=True);thread.start()
        else:
            display('加载 NIGHT 固件','先做两分钟亮度检查，再做空场/有人各一分钟方向检查。','离线 ±1 核对未通过，依据用户后续“上板”指令做候选诊断。')
            load('NIGHT')
            bright=phase('BRIGHTNESS_NIGHT',120,'亮度检查两分钟，保持拍摄灯光和相机位置。',True)
            if bright.get('brightness_over_130'):
                stop_reader();selected='DAY';load('DAY')
                bright=phase('BRIGHTNESS_DAY',120,'已切换DAY低增益预设，再检查亮度两分钟。',True)
                if bright.get('brightness_over_130'):cap.log('### ISSUE DAY mean_sensor > 130; recorded without further camera adjustment; continuing next task')
        empty=phase('DIRECTION_EMPTY',60,'分数方向检查。接下来一分钟保持空场，室友在座算背景，测试者完全离开画面。')
        present=phase('DIRECTION_PERSON',60,'分数方向检查。接下来一分钟测试者进入画面，站在镜头前一到两米，走动或转身。')
        results['direction']=dict(empty=empty,present=present,scene_truth='prompted protocol; independently unverified')
        if empty['p_median'] is not None and present['p_median'] is not None and empty['p_median']>0 and present['p_median']<0:
            raise RuntimeError('Reversed score signs in prompted windows; stop as requested; human scene content still requires image review')
        if empty['p_median'] is None or present['p_median'] is None or empty['p_median']>=0 or present['p_median']<=0:
            cap.log('### ISSUE score direction not demonstrated; report missing/ambiguous observations; phases are not truth labels')
        results['free_capture']=phase('FREE_MOVEMENT',1800,'开始三十分钟自由走动。室友可以照常坐着；测试者自由进出、走动、靠近镜头。无需按键，真值之后看图判定。')
    except Exception as exc:
        error=repr(exc);cap.log('### ACQUISITION_ERROR '+error);print('V29_GATE_ERROR',error,flush=True)
    finally:
        stop_reader();cap.log('### CAPTURE_END');cap.fh.close();cap.uart_fh.close()
        result=dict(ended_wall=loader.wall(),error=error,port_closed=True,selected_preset=selected,firmware=identity[selected],
            bitstream_sha256=continuous.M15,gaps=cap.gaps,reconnects=cap.reconnects,phases=events,results=results,
            fixed_readbacks=cap.fixed,offline_check_passed=False,
            authorization='User subsequently instructed serial reconnected and 上板 after the offline discrepancy was reported',
            truth_source='Claude reviews exported images; scheduled phases are not labels')
        continuous.save(OUT/'run_metadata.json',result)
        display('采集已保存',error or '三十分钟采集结束，正在整理数据。','结果与异常将写入 comms/。')
        try:panel.stdin.close();panel.wait(timeout=3)
        except Exception:pass
    return 1 if error else 0


if __name__=='__main__':raise SystemExit(main())
