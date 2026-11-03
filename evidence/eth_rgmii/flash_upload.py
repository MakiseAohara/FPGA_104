import subprocess, time, hashlib, sys
BIT = r'D:\eth_build\m17_ge\outflow\ti60f225_oob.bit'
IMG = r'D:\v30_build\out_v30_v67\tinyml_pdti8.bin'
sha = hashlib.sha256(open(BIT,'rb').read()).hexdigest().upper()
out = subprocess.run(['powershell','-NoProfile','-Command',
    "Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -match 'web_monitor' } | ForEach-Object { $_.ProcessId }"],
    capture_output=True, text=True).stdout
for pid in [x.strip() for x in out.split() if x.strip().isdigit()]:
    subprocess.run(['taskkill','/F','/PID',pid], capture_output=True)
time.sleep(1)
for att in range(1, 4):
    f = subprocess.run(['powershell','-NoProfile','-ExecutionPolicy','Bypass','-File',
                        r'D:\v30_build\flash_vendor_utf8.ps1','-Bit',BIT,'-Sha256',sha,'-Force'],
                       capture_output=True, text=True, errors='replace', timeout=300)
    fo = (f.stdout or '') + (f.stderr or '')
    ok = ('finished with JTAG programming' in fo)
    print('attempt', att, 'flash', 'OK' if ok else 'FAIL', flush=True)
    if not ok:
        time.sleep(2); continue
    u = subprocess.run(['py','-3','-u',r'D:\v30_build\load_v30.py','--image',IMG,'--out',r'out\live_rx4'],
                       capture_output=True, text=True, errors='replace', timeout=240)
    uo = (u.stdout or '') + (u.stderr or '')
    print('  upload:', 'OK' if 'LOAD_PASS_CONFIRMED' in uo else 'FAIL', flush=True)
    if 'LOAD_PASS_CONFIRMED' in uo:
        sys.exit(0)
    time.sleep(1)
print('FAILED')
