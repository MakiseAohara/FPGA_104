"""UART 载入 + 抓取（v30 用）：等 MMT_LOADER_READY → 传镜像 → 连续抓串口。
用法：
  py -3 load_v30.py --image <bin> --out <dir> --capture-seconds 45
  py -3 load_v30.py --no-upload --out <dir> --capture-seconds 30   # 板上已在跑时只抓
"""
import argparse, binascii, struct, sys, time
from pathlib import Path
import serial

ap = argparse.ArgumentParser()
ap.add_argument('--port', default='COM15')
ap.add_argument('--image', type=Path)
ap.add_argument('--out', type=Path, required=True)
ap.add_argument('--boot-timeout', type=float, default=120.0)
ap.add_argument('--capture-seconds', type=float, default=45.0)
ap.add_argument('--no-upload', action='store_true')
a = ap.parse_args()
a.out.mkdir(parents=True, exist_ok=True)
log = (a.out / 'serial.log').open('w', encoding='utf-8', newline='\n')
raw = bytearray()

def emit(line: bytes):
    text = line.decode('ascii', errors='replace').rstrip('\r')
    stamp = time.strftime('%H:%M:%S')
    log.write(f'{stamp} {text}\n'); log.flush()
    print(text, flush=True)
    return text

def read_lines(port, buffer, deadline):
    while time.monotonic() < deadline:
        chunk = port.read(max(1, port.in_waiting))
        if chunk:
            raw.extend(chunk); buffer.extend(chunk)
            while b'\n' in buffer:
                line, tail = buffer.split(b'\n', 1); buffer[:] = tail
                emit(line)
    return buffer

def find_token(port, buffer, tokens, timeout):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        chunk = port.read(max(1, port.in_waiting))
        if not chunk:
            continue
        raw.extend(chunk); buffer.extend(chunk)
        while b'\n' in buffer:
            line, tail = buffer.split(b'\n', 1); buffer[:] = tail
            text = emit(line)
            if any(t in text for t in tokens):
                return text
    return None

with serial.Serial(a.port, 115200, timeout=0.05, write_timeout=5) as port:
    port.reset_input_buffer()
    print(f'HOST_OPEN {a.port}', flush=True)
    buffer = bytearray()
    t0 = time.monotonic()
    if not a.no_upload:
        ready = find_token(port, buffer, ['MMT_LOADER_READY'], a.boot_timeout)
        if not ready:
            print('LOADER_NOT_READY', flush=True); sys.exit(2)
        data = a.image.read_bytes()
        crc = binascii.crc32(data) & 0xFFFFFFFF
        print(f'UPLOAD {len(data)} B crc32={crc:08X}', flush=True)
        port.write(b'MMTL' + struct.pack('<II', len(data), crc))
        if not find_token(port, buffer, ['MMT_LOAD_ACCEPT'], 5):
            print('LOAD_NOT_ACCEPTED', flush=True); sys.exit(3)
        for off in range(0, len(data), 64):
            block = data[off:off+64]
            ack = b''
            for attempt in range(3):            # 块级重试：丢 ACK 是这块板的老毛病
                port.write(block)
                deadline = time.monotonic() + 8.0
                while time.monotonic() < deadline:
                    c = port.read(1)
                    if c == b'\x06':
                        ack = c
                        break
                    if c:
                        print(f'  STRAY block={off//64} byte=0x{c.hex()}', flush=True)
                if ack == b'\x06':
                    break
                print(f'  RETRY block={off//64} attempt={attempt+1}', flush=True)
            if ack == b'\x06':
                time.sleep(0.003)               # 节奏控制：给板端 UART→DDR 留出时间
            if ack != b'\x06':
                print(f'ACK_FAIL block={off//64} at {off*100//len(data)}%', flush=True); sys.exit(4)
            if (off // 64) % 800 == 0:
                print(f'  {off*100//len(data)}% ({off//64} blocks)', flush=True)
        print('UPLOAD_DONE', flush=True)
    read_lines(port, buffer, time.monotonic() + a.capture_seconds)

(a.out / 'uart_raw.bin').write_bytes(bytes(raw))
log.close()
print('CAPTURE_DONE bytes=', len(raw), flush=True)
