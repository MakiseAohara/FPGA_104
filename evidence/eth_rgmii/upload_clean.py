import subprocess, time
def monitors():
    out = subprocess.run(['powershell','-NoProfile','-Command',
        "Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -match 'web_monitor' } | ForEach-Object { $_.ProcessId }"],
        capture_output=True, text=True).stdout
    return [int(x) for x in out.split() if x.strip().isdigit()]
for i in range(5):
    pids = monitors()
    if not pids:
        break
    for pid in pids:
        subprocess.run(['taskkill','/F','/PID',str(pid)], capture_output=True)
    print('killed', pids, flush=True)
    time.sleep(0.6)
print('remaining', monitors(), flush=True)
time.sleep(1.5)
r = subprocess.run(['py','-3','-u',r'D:\v30_build\load_v30.py','--image', r'D:\v30_build\out_v30_v67\tinyml_pdti8.bin',
                    '--out', r'out\live_rx6'], capture_output=True, text=True, errors='replace', timeout=200)
o = (r.stdout or '') + (r.stderr or '')
print('upload rc', r.returncode, 'OK' if 'LOAD_PASS_CONFIRMED' in o else 'FAIL')
print(o.strip().splitlines()[-1][:120] if o.strip() else '')
