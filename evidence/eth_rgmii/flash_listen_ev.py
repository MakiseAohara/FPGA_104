import subprocess, time, hashlib, socket, struct, collections
BIT = r'D:\eth_build\m17_ge\outflow\ti60f225_oob.bit'
IMG = r'D:\v30_build\out_v30_e4\tinyml_pdti8.bin'
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
u = subprocess.run(['py','-3','-u',r'D:\v30_build\load_v30.py','--image',IMG,'--out',r'out\ev2'],
                   capture_output=True, text=True, errors='replace', timeout=240)
o = (u.stdout or '') + (u.stderr or '')
print('upload', 'OK' if 'LOAD_PASS_CONFIRMED' in o else 'FAIL', flush=True)
time.sleep(3)
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(('0.0.0.0', 8080)); s.settimeout(0.5)
cnt = collections.Counter(); hb=[]; evs=[]
t0=time.time()
while time.time()-t0 < 12:
    try: d,a = s.recvfrom(2048)
    except socket.timeout: continue
    if d[:2] != b'MT': cnt['bad']+=1; continue
    typ=d[3]; cnt[typ]+=1
    if typ==2: hb.append(time.time()-t0)
    if typ==1: evs.append(d[16:21])
s.close()
print('counts', dict(cnt), flush=True)
if len(hb)>1:
    g=[hb[i+1]-hb[i] for i in range(len(hb)-1)]
    print('hb gaps mean %.2f min %.2f max %.2f' % (sum(g)/len(g), min(g), max(g)), flush=True)
print('events', evs[:5], flush=True)
