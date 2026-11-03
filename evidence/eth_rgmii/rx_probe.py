import serial, time, subprocess, threading
res = []
def pinger():
    time.sleep(1.0)
    subprocess.run(['ping','-n','2','-w','600','169.254.47.62'], capture_output=True)
th = threading.Thread(target=pinger); th.start()
p = serial.Serial(None); p.port='COM15'; p.dtr=False; p.rts=False
p.open(); p.timeout=0.5
buf = b''
end = time.time() + 6
while time.time() < end:
    buf += p.read(8192)
p.close(); th.join()
t = buf.decode('utf-8','replace')
lines = [l for l in t.splitlines() if 'MMT_GE' in l]
print('GE lines', len(lines))
for l in lines[-4:]:
    print(l.strip())
