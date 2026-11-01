import sys, time
from pathlib import Path
sys.path.append(r'D:\Efinity\2026.1\python311\Lib\site-packages')
import serial
OUT = Path(r'C:\Users\Makise Aohara\Documents\deepseek-harness\default-workspace\_v29work\FPGA_104-main\evidence\v29_gate\v291')
p = serial.Serial('COM15', 115200, timeout=0.2); p.dtr=False; p.rts=False
fh = (OUT / 'phase_b_direction.log').open('wb')
t0 = time.time()
while time.time() - t0 < 300:
    c = p.read(512)
    if c: fh.write(c)
fh.close(); p.close()
print('done')
