import subprocess, time
def monitors():
    out = subprocess.run(['powershell','-NoProfile','-Command',
        "Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -match 'web_monitor' } | ForEach-Object { $_.ProcessId }"],
        capture_output=True, text=True).stdout
    return [int(x) for x in out.split() if x.strip().isdigit()]
for i in range(4):
    p = monitors()
    if not p: break
    for pid in p: subprocess.run(['taskkill','/F','/PID',str(pid)], capture_output=True)
    time.sleep(0.5)
print('remaining', monitors(), flush=True)
r = subprocess.run(['py','-3','-u',r'D:\v30_build\load_v30.py','--image', r'D:\v30_build\out_v30_v67\tinyml_pdti8.bin',
                    '--out', r'out\live_rx7'], capture_output=True, text=True, errors='replace', timeout=200)
o = (r.stdout or '') + (r.stderr or '')
print('upload', 'OK' if 'LOAD_PASS_CONFIRMED' in o else 'FAIL')
