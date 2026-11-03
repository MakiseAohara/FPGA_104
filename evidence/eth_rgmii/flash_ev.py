import subprocess, time, hashlib, socket, struct, sys
BIT = r'D:\eth_build\m17_ge\outflow\ti60f225_oob.bit'
IMG = r'D:\v30_build\out_v30_t8\tinyml_pdti8.bin'
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
u = subprocess.run(['py','-3','-u',r'D:\v30_build\load_v30.py','--image',IMG,'--out',r'out\ev1'],
                   capture_output=True, text=True, errors='replace', timeout=240)
o = (u.stdout or '') + (u.stderr or '')
print('upload', 'OK' if 'LOAD_PASS_CONFIRMED' in o else 'FAIL', flush=True)
