import subprocess, time, hashlib, serial, threading
BIT = r'D:\eth_build\m17_ge\outflow\ti60f225_oob.bit'
IMG = r'D:\v30_build\out_v30_v71\tinyml_pdti8.bin'
sha = hashlib.sha256(open(BIT,'rb').read()).hexdigest().upper()
def pids(pat):
    out = subprocess.run(['powershell','-NoProfile','-Command',
        "Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -match '%s' } | ForEach-Object { $_.ProcessId }" % pat],
        capture_output=True, text=True).stdout
    return [int(x) for x in out.split() if x.strip().isdigit()]
for pat in ('mot_service','web_monitor'):
    for _ in range(3):
        p = pids(pat)
        if not p: break
        for pid in p: subprocess.run(['taskkill','/F','/PID',str(pid)], capture_output=True)
        time.sleep(0.4)
time.sleep(0.8)
f = subprocess.run(['powershell','-NoProfile','-ExecutionPolicy','Bypass','-File',
                    r'D:\v30_build\flash_vendor_utf8.ps1','-Bit',BIT,'-Sha256',sha,'-Force'],
                   capture_output=True, text=True, errors='replace', timeout=300)
print('flash', 'OK' if 'finished with JTAG programming' in ((f.stdout or '')+(f.stderr or '')) else 'FAIL', flush=True)
u = subprocess.run(['py','-3','-u',r'D:\v30_build\load_v30.py','--image',IMG,'--out',r'out\live_z4'],
                   capture_output=True, text=True, errors='replace', timeout=240)
o = (u.stdout or '') + (u.stderr or '')
print('upload', 'OK' if 'LOAD_PASS_CONFIRMED' in o else 'FAIL', flush=True)
if 'LOAD_PASS_CONFIRMED' not in o: raise SystemExit(1)
time.sleep(3)
buf = []
def reader():
    p = serial.Serial(None); p.port='COM15'; p.baudrate=115200; p.dtr=False; p.rts=False
    p.open(); p.timeout=0.3
    end = time.time()+12
    while time.time() < end: buf.append(p.read(8192))
    p.close()
th = threading.Thread(target=reader); th.start()
time.sleep(1.5)
r = subprocess.run(['ping','-n','5','-w','600','169.254.47.62'], capture_output=True, text=True, errors='replace')
print('ping:', [l for l in r.stdout.splitlines() if 'loss' in l][-1:], flush=True)
th.join()
t = b''.join(buf).decode('utf-8','replace')
lines = [l for l in t.splitlines() if 'MMT_GE' in l]
print('GE lines', len(lines), flush=True)
for l in lines[-3:]: print(l.strip(), flush=True)
