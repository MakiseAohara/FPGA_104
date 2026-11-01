"""v29.1 board bring-up: flash MERGE16 over JTAG, upload firmware over UART, log boot."""
import argparse, binascii, hashlib, os, struct, subprocess, sys, time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
FLASH = Path(r'C:\Users\Makise Aohara\Documents\Codex\2026-10-15\https-github-com-makiseaohara-fpga-104\outputs\fpga_onboard_verified_20261020\tools\flash_vendor.ps1')
EFINITY = Path(r'D:\Efinity\2026.1')
BIT = ROOT / 'evidence/v27_rtl_ir/../v29_rtl_display/v7_MERGE16.bit'
BIT_SHA = '81332CD17DA35CDB7103C666434AE0DF1702A65EBEAEAAEB80AE70C8801F8882'

ap = argparse.ArgumentParser()
ap.add_argument('--port', default='COM15')
ap.add_argument('--firmware', default=str(ROOT / 'evidence/v29_fw/tinyml_pdti8_v291_daycal.bin'))
ap.add_argument('--out', default=str(ROOT / 'evidence/v29_gate/v291'))
ap.add_argument('--capture-seconds', type=float, default=40.0)
ap.add_argument('--no-flash', action='store_true')
args = ap.parse_args()
OUT = Path(args.out); OUT.mkdir(parents=True, exist_ok=True)

def wall():
    import datetime as dt
    return dt.datetime.now(dt.timezone(dt.timedelta(hours=8))).isoformat(timespec='milliseconds')

def ps_env():
    env = os.environ.copy()
    for k in list(env):
        if k.upper() in ('PYTHONHOME', 'PSMODULEPATH'):
            env.pop(k)
    env['PSModulePath'] = (r'C:\Windows\System32\WindowsPowerShell\v1.0\Modules;'
                           r'C:\Program Files\WindowsPowerShell\Modules')
    return env

sha = hashlib.sha256(BIT.read_bytes()).hexdigest().upper()
print('BIT', BIT.name, BIT.stat().st_size, sha, flush=True)
if sha != BIT_SHA:
    raise SystemExit('MERGE16 sha mismatch: ' + sha)

data = Path(args.firmware).read_bytes()
crc = binascii.crc32(data) & 0xffffffff
print('FW', Path(args.firmware).name, len(data), '%08X' % crc, flush=True)

sys.path.append(str(EFINITY / 'python311/Lib/site-packages'))
import serial

log_path = OUT / 'board_v291.log'
fh = log_path.open('w', encoding='utf-8', newline='\n')

def log(text):
    fh.write(wall() + '\t' + text + '\n'); fh.flush()

port = serial.Serial(port=None, baudrate=115200, timeout=0.05, write_timeout=5)
port.dtr = False; port.rts = False; port.port = args.port; port.open()

buf = b''
def readline(timeout):
    global buf
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        chunk = port.read(256)
        if chunk:
            buf += chunk
            while b'\n' in buf:
                line, buf = buf.split(b'\n', 1)
                text = line.decode('utf-8', 'replace').rstrip('\r')
                log(text)
                return text
        else:
            time.sleep(0.005)
    return None

def until(token, timeout):
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        line = readline(max(0.1, end - time.monotonic()))
        if line and token in line:
            print(line, flush=True)
            return line
    raise TimeoutError('waiting for ' + token)

flash = None
if not args.no_flash:
    cmd = [r'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe', '-NoProfile',
           '-ExecutionPolicy', 'Bypass', '-File', str(FLASH),
           '-Bit', str(BIT), '-Sha256', BIT_SHA, '-EfinityHome', str(EFINITY),
           '-ExpectedDriverVersion', '2.12.36.20', '-UsbUrl', 'hiftdi://0x0403:0x6011/1',
           '-LogRoot', str(OUT / 'flash_logs')]
    flog = (OUT / 'flash_stdout.log').open('wb')
    flash = subprocess.Popen(cmd, stdout=flog, stderr=subprocess.STDOUT, env=ps_env())
    print('### FLASH_START pid=%d' % flash.pid, flush=True)
    ready = False
    end = time.monotonic() + 150
    while time.monotonic() < end:
        line = readline(0.2)
        if line and 'MMT_LOADER_READY' in line:
            ready = True
        if flash.poll() is not None:
            print('### FLASH_EXIT', flash.returncode, flush=True)
            if flash.returncode != 0:
                raise SystemExit('flash failed, see ' + str(OUT / 'flash_stdout.log'))
            break
    if not ready:
        # efx_pgm returns before the SoC finishes reconfiguring; keep listening.
        print('### WAIT_LOADER_AFTER_FLASH', flush=True)
        until('MMT_LOADER_READY', 40)
    print('### FLASH_OK', flush=True)

header = b'MMTL' + struct.pack('<II', len(data), crc)
accepted = False
for attempt in range(15):
    port.write(header)
    try:
        until('MMT_LOAD_ACCEPT', 0.4)
        accepted = True
        break
    except TimeoutError:
        continue
if not accepted:
    raise SystemExit('loader did not accept header after 15 tries')
t0 = time.monotonic()
for off in range(0, len(data), 64):
    block = data[off:off + 64]
    acked = False
    for attempt in range(4):
        port.write(block)
        end = time.monotonic() + 8
        while time.monotonic() < end:
            c = port.read(1)
            if c == b'\x06':
                acked = True
                break
            if c:
                buf += c
        if acked:
            break
    if not acked:
        raise SystemExit('block %d not acked' % (off // 64))
print('### UPLOAD_DONE %.1fs' % (time.monotonic() - t0), flush=True)
until('MMT_LOAD_PASS DDR_CRC', 60)
until('MMT_LIVE_BOOT', 30)

print('### CAPTURE %ss' % args.capture_seconds, flush=True)
end = time.monotonic() + args.capture_seconds
while time.monotonic() < end:
    line = readline(0.2)
    if line and line.startswith(('MMT_WB', 'MMT_FUSION', 'MMT_LIVE_BOOT', 'MMT_CAM_PRESET',
                                 'MMT_BRIGHT', 'MMT_LIVE_MODEL', 'MMT_ALARM', 'MMT_LIVE_HW')):
        print(line, flush=True)
port.close(); fh.close()
print('### END', flush=True)
