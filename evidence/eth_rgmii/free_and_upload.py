import subprocess, time, re, os
# 1) 找到并杀掉占用 COM15 的 web_monitor
out = subprocess.run(['powershell','-NoProfile','-Command',
    "Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -match 'web_monitor' } | ForEach-Object { $_.ProcessId }"],
    capture_output=True, text=True).stdout
pids = [x.strip() for x in out.split() if x.strip().isdigit()]
for pid in pids:
    subprocess.run(['taskkill','/F','/PID',pid], capture_output=True)
    print('killed', pid)
time.sleep(1)
# 2) 上传固件
r = subprocess.run(['py','-3','-u',r'D:\v30_build\load_v30.py','--image', r'D:\v30_build\out_v30_v63\tinyml_pdti8.bin',
                    '--out', r'out\dbg_speed'], capture_output=True, text=True, errors='replace', timeout=240)
tail = [l for l in (r.stdout + r.stderr).splitlines() if ('LOAD' in l or 'UPLOAD' in l)][-6:]
print('\n'.join(tail))
