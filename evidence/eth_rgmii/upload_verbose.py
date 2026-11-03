import subprocess, time
r = subprocess.run(['py','-3','-u',r'D:\v30_build\load_v30.py','--image', r'D:\v30_build\out_v30_v67\tinyml_pdti8.bin',
                    '--out', r'out\live_rx5'], capture_output=True, text=True, errors='replace', timeout=200)
o = (r.stdout or '') + (r.stderr or '')
print('rc', r.returncode)
print(o[-1200:])
