"""Load a bounded DDR image through the on-chip UART loader; no Flash access."""
import argparse,binascii,json,struct,time
from pathlib import Path
import serial

ap=argparse.ArgumentParser(description=__doc__)
ap.add_argument('--port',required=True)
ap.add_argument('--image',type=Path)
ap.add_argument('--out',type=Path,required=True)
ap.add_argument('--boot-timeout',type=float,default=15)
ap.add_argument('--run-timeout',type=float,default=180)
a=ap.parse_args();a.out.mkdir(parents=True,exist_ok=True)
capture=bytearray();buffer=bytearray();lines=[];status={'board_inference_passed':False}
start=time.monotonic()
def emit(line):
    text=line.decode('ascii',errors='replace').strip()
    lines.append(text)
    if text:print(text,flush=True)
    (a.out/'uart_live.bin').write_bytes(capture)
    return text
try:
    with serial.Serial(a.port,115200,timeout=0.05,write_timeout=3) as port:
        print('HOST_SERIAL_OPEN',a.port,'115200 8N1',flush=True)
        def line_until(tokens,timeout):
            deadline=time.monotonic()+timeout
            while time.monotonic()<deadline:
                if b'\n' in buffer:
                    line,tail=buffer.split(b'\n',1);buffer[:]=tail
                    text=emit(line)
                    if any(token in text for token in tokens):return text
                    if 'MMT_DDR_FAIL' in text or 'MMT_LOAD_FAIL' in text or 'MMT_AI_FAIL' in text:
                        raise RuntimeError(text)
                else:
                    chunk=port.read(max(1,port.in_waiting));capture.extend(chunk);buffer.extend(chunk)
            raise TimeoutError('Waiting for '+repr(tokens))
        line_until(['MMT_LOADER_READY'],a.boot_timeout)
        status['ddr_loader_ready']=True
        if a.image:
            data=a.image.read_bytes()
            if not 0<len(data)<=0x800000:raise ValueError('Image exceeds loader window')
            crc=binascii.crc32(data)&0xFFFFFFFF
            status.update(image=str(a.image),length=len(data),crc32=f'{crc:08X}')
            port.write(b'MMTL'+struct.pack('<II',len(data),crc))
            line_until(['MMT_LOAD_ACCEPT'],3)
            last=-1
            for offset in range(0,len(data),64):
                block=data[offset:offset+64]
                if port.write(block)!=len(block):raise IOError('Short UART write')
                deadline=time.monotonic()+2
                ack=b''
                while not ack and time.monotonic()<deadline:ack=port.read(1)
                if ack!=b'\x06':raise IOError(f'Block {offset//64} acknowledgement {ack!r}')
                percent=(offset+len(block))*10//len(data)
                if percent!=last:
                    print('IMAGE_UPLOAD',percent*10,'%',flush=True);last=percent
            line_until(['MMT_LOAD_PASS DDR_CRC'],30)
            status['ddr_image_crc_passed']=True
            terminal=line_until(['MMT_AI_PASS','MMT_AI_FAIL'],a.run_timeout)
            status['board_inference_passed']=('MMT_AI_PASS 2/2 HARDWARE_ENABLED' in terminal)
        else:
            status['observe_only']=True
except Exception as error:
    status['error']=repr(error)
    print('HOST_TEST_FAILED',repr(error),flush=True)
finally:
    status['elapsed_s']=time.monotonic()-start
    (a.out/'uart_capture.bin').write_bytes(capture)
    (a.out/'uart_capture.txt').write_text('\n'.join(lines)+'\n',encoding='utf-8')
    (a.out/'result.json').write_text(json.dumps(status,indent=2),encoding='utf-8')
    print(json.dumps(status,indent=2),flush=True)
raise SystemExit(0 if status.get('board_inference_passed') or status.get('observe_only') else 1)
