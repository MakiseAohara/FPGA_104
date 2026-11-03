import subprocess, time
def pids(pattern):
    out = subprocess.run(['powershell','-NoProfile','-Command',
        "Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -match '%s' } | ForEach-Object { $_.ProcessId }" % pattern],
        capture_output=True, text=True).stdout
    return [int(x) for x in out.split() if x.strip().isdigit()]
for _ in range(3):
    p = pids('mot_service')
    if not p: break
    for pid in p: subprocess.run(['taskkill','/F','/PID',str(pid)], capture_output=True)
    print('killed watchdog', p, flush=True); time.sleep(0.6)
time.sleep(1)
for _ in range(4):
    p = pids('web_monitor')
    if not p: break
    for pid in p: subprocess.run(['taskkill','/F','/PID',str(pid)], capture_output=True)
    print('killed monitor', p, flush=True); time.sleep(0.6)
print('left', pids('web_monitor|mot_service'), flush=True)
r = subprocess.run(['py','-3','-u',r'D:\v30_build\load_v30.py','--image', r'D:\v30_build\out_v30_v67\tinyml_pdti8.bin',
                    '--out', r'out\live_rx8'], capture_output=True, text=True, errors='replace', timeout=200)
o = (r.stdout or '') + (r.stderr or '')
print('upload', 'OK' if 'LOAD_PASS_CONFIRMED' in o else 'FAIL', flush=True)
