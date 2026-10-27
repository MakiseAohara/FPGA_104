"""Acquire device-marked A-F scenes. Prompts are not verified human labels."""
import base64
import csv
import hashlib
import importlib.util
import json
from pathlib import Path
import re
import subprocess
import sys
import threading
import time
import zlib

sys.dont_write_bytecode=True
HERE=Path(__file__).resolve().parent;ROOT=HERE.parents[1]
spec=importlib.util.spec_from_file_location('continuous',ROOT/'evidence/v28_gate/capture_v28.py')
continuous=importlib.util.module_from_spec(spec);spec.loader.exec_module(continuous);loader=continuous.loader
KV=re.compile(r'\b([A-Za-z_][A-Za-z0-9_]*)=([^\s]+)')
PROMPTS={
 'A':'A段，空场三分钟。人完全离开镜头，不动任何东西，背景和灯光保持不变。',
 'B':'B段，三分钟。人不要入画，在镜头外挪椅子、放下或拿走包和杂物、拉动窗帘，开关一次台灯。曝光和增益保持固定。',
 'C':'C段，三分钟。一人穿深色衣服，在画面内走动和转身。下一段需要浅色衣服，或换另一位同学。',
 'D':'D段，三分钟。换浅色衣服或另一位同学，在画面内走动和转身。',
 'E':'E段，三分钟。人坐下、低头、侧身、只露半身，或者站在画面边缘。',
 'F':'F段，三分钟。人交替进出画面，每次间隔五到十秒；接下来会有七点五秒的进出提示。'}


class Capture(continuous.Capture):
    def __init__(self,out):
        super().__init__(out);self.fh.close();(out/'log_v28_gate.log').rename(out/'log_v29_scene.log')
        self.fh=(out/'log_v29_scene.log').open('a',encoding='utf-8',newline='\n')
        self.marks=[];self.current=None;self.current_since=None;self.done=threading.Event()
        self.locked=None;self.cal_steps=[];self.errors=[];self.images=0;self.group_rows=set()
    def log(self,text,serial_line=False):
        super().log(text,serial_line)
        if not serial_line:return
        fields=dict(KV.findall(text))
        if text.startswith('MMT_BRIGHT_LOCKED '):self.locked=fields
        elif text.startswith('MMT_BRIGHT_STEP '):self.cal_steps.append(fields)
        elif text.startswith(('MMT_BRIGHT_ERROR','MMT_SCENE_ERROR')):self.errors.append(text)
        elif text.startswith('MMT_MARK '):
            row=dict(fields,wall=loader.wall());self.marks.append(row)
            if fields.get('edge')=='START' or (fields.get('edge')=='STATE' and fields.get('seg')!=self.current):
                self.current=fields['seg'];self.current_since=time.monotonic()
            if fields.get('seg')=='F' and fields.get('edge')=='END':self.done.set()
        elif text.startswith('MMT_SCENE_DONE'):self.done.set()
        elif text.startswith('MMT_IMGSTAT '):self.group_rows=set()
        elif text.startswith('MMT_IMG '):
            match=re.fullmatch(r'MMT_IMG\s+(\d{1,2})\s+[0-9a-fA-F]{192}',text)
            if match:
                self.group_rows.add(int(match[1]))
                if len(self.group_rows)==96:self.images+=1;self.group_rows=set()


def speak(text):
    command="Add-Type -AssemblyName System.Speech; $s=New-Object System.Speech.Synthesis.SpeechSynthesizer; $s.Speak('"+text.replace("'","''")+"')"
    try:subprocess.Popen([loader.powershell(),'-NoProfile','-EncodedCommand',base64.b64encode(command.encode('utf-16le')).decode()],
                        env=loader.powershell_env(),stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,creationflags=subprocess.CREATE_NO_WINDOW)
    except OSError:pass


def main():
    import argparse
    options=argparse.ArgumentParser()
    options.add_argument('--attempt',type=int,choices=[1,2,3],default=1)
    attempt=options.parse_args().attempt
    args=argparse.Namespace(out=HERE,port='COM15',image=HERE/'tinyml_pdti8_v29_scene.bin',
       bit=ROOT/'evidence/v27_rtl_ir/v7_MERGE15.bit',efinity=Path(r'D:\Efinity\2026.1'),
       flash=Path(r'C:\Users\Makise Aohara\Documents\Codex\2026-10-15\https-github-com-makiseaohara-fpga-104\outputs\fpga_onboard_verified_20261020\tools\flash_vendor.ps1'))
    identity=json.loads((HERE/'firmware_manifest.json').read_text(encoding='utf-8'))
    data=args.image.read_bytes();assert hashlib.sha256(data).hexdigest().upper()==identity['sha256'] and f'{zlib.crc32(data):08X}'==identity['crc32']
    assert hashlib.sha256(args.bit.read_bytes()).hexdigest().upper()==continuous.M15
    loader.BIT_SHA=continuous.M15;loader.CRC=identity['crc32'];loader.SHA=identity['sha256']
    sys.path.append(str(args.efinity/'python311/Lib/site-packages'));import serial
    cap=Capture(HERE);reader=thread=None;error=None
    metadata=dict(started_wall=loader.wall(),attempt=attempt,firmware=identity,bitstream_sha256=continuous.M15,
       requested_segment_seconds=180,requested_segments=list('ABCDEF'),background_fixed_requested=True,
       scene_class_source='requested timed protocol; not independently verified frame truth',
       lighting='operator requested to keep video lighting; no software light changes',automatic_exposure_during_segments=False,
       calibration_before_A=True,formal_firmware_dump_every=40,temporary_dump_every=3)
    panel=subprocess.Popen([loader.powershell(),'-NoProfile','-STA','-ExecutionPolicy','Bypass','-File',str(HERE/'phase_panel.ps1')],
             stdin=subprocess.PIPE,text=True,encoding='utf-8',env=loader.powershell_env(),creationflags=subprocess.CREATE_NO_WINDOW)
    prompts=[];seen=0;announced=None;last_progress=0;warned=set();last_fcue=0;f_count=0
    def display(title,instruction,status,done=False):
        try:panel.stdin.write(json.dumps(dict(title=title,instruction=instruction,status=status,done=done),ensure_ascii=False)+'\n');panel.stdin.flush()
        except (OSError,ValueError):pass
    try:
        display('正在加载采集固件','相机和拍视频时的灯光保持固定；校准完成后自动开始A段。','请按提示执行实际动作；提示本身不是训练真值。')
        reader=loader.flash_and_upload(args,cap,serial,data,attempt)
        thread=threading.Thread(target=continuous.receive,args=(reader,cap,serial,args.port),daemon=True);thread.start()
        deadline=time.monotonic()+1260
        while time.monotonic()<deadline and not cap.done.is_set():
            if cap.errors:raise RuntimeError('; '.join(cap.errors))
            if cap.current and cap.current!=announced:
                announced=cap.current;instruction=PROMPTS[announced];speak(instruction)
                prompts.append(dict(wall=loader.wall(),seg=announced,kind='segment_prompt',text=instruction))
                print('SCENE_START',announced,loader.wall(),cap.locked,flush=True);last_fcue=time.monotonic()
            remaining=max(0,180-(time.monotonic()-cap.current_since)) if cap.current_since else 180
            if cap.current=='C' and remaining<=30 and 'D' not in warned:
                text='三十秒后进入D段，请准备浅色衣服或另一位同学。';speak(text);warned.add('D');prompts.append(dict(wall=loader.wall(),seg='C',kind='advance_prompt',text=text))
            if cap.current=='F' and time.monotonic()-last_fcue>=7.5:
                text='进入画面' if f_count%2==0 else '离开画面';speak(text);f_count+=1;last_fcue=time.monotonic()
                prompts.append(dict(wall=loader.wall(),seg='F',kind='scheduled_movement_cue_not_truth',text=text))
            if time.monotonic()-last_progress>=5:
                display(f"{cap.current or '校准'}段  剩余约{remaining:05.1f}秒",PROMPTS.get(cap.current,'正在选择并验证固定曝光和增益；尚未开始六段场景。'),
                        f'完整图组={cap.images}   GAP={cap.gaps}   重连={cap.reconnects}；设备实际段号以MMT_MARK为准')
                progress=dict(wall=loader.wall(),segment=cap.current,segment_remaining_s=round(remaining,2),images=cap.images,gaps=cap.gaps,reconnects=cap.reconnects,locked=cap.locked)
                try:continuous.save(HERE/'run_progress.json',progress)
                except OSError as exc:cap.log('### PROGRESS_ERROR '+repr(exc))
                last_progress=time.monotonic()
            time.sleep(.1)
        if not cap.done.is_set():raise TimeoutError('No F-END/DONE received within 21 minutes')
        metadata['scene_sequence_completed']=True;speak('六段采集结束，正在保存数据，恢复正式固件。')
    except Exception as exc:error=repr(exc);print('SCENE_CAPTURE_ERROR',error,flush=True);cap.log('### ACQUISITION_ERROR '+error)
    finally:
        cap.stop.set()
        if thread:thread.join(timeout=3)
        if reader:
            if reader.buf:cap.log('### FINAL_PARTIAL_LINE_HEX '+reader.buf.hex())
            reader.port.close()
        cap.log('### CAPTURE_END');cap.fh.close();cap.uart_fh.close()
        metadata.update(ended_wall=loader.wall(),error=error,port_closed=True,locked=cap.locked,calibration_steps=cap.cal_steps,
             marks=cap.marks,gaps=cap.gaps,reconnects=cap.reconnects,complete_image_groups_observed=cap.images)
        continuous.save(HERE/'run_metadata.json',metadata)
        for name,rows,columns in [('segment_events.csv',cap.marks,['seg','edge','ms','target_ms','f','vts','exp20','gc','gf','cam_ok','wall']),
                                  ('action_prompts.csv',prompts,['wall','seg','kind','text'])]:
            with (HERE/name).open('w',encoding='utf-8',newline='') as stream:
                writer=csv.DictWriter(stream,fieldnames=columns,extrasaction='ignore');writer.writeheader();writer.writerows(rows)
        display('采集已保存',error or '六段结束；场景内容待按图复核。','相机参数与实际段落时间已记录。',True)
        try:panel.stdin.close();panel.wait(timeout=3)
        except Exception:pass
    return 1 if error else 0


if __name__=='__main__':raise SystemExit(main())
