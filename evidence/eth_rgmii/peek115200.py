import serial, time, sys
port = sys.argv[1] if len(sys.argv) > 1 else 'COM15'
p = serial.Serial(None); p.port = port; p.baudrate = 115200; p.dtr=False; p.rts=False
p.open(); p.timeout=0.4
t = b''
end = time.time()+2.5
while time.time()<end: t += p.read(8192)
p.close()
txt = t.decode('utf-8','replace')
lines = [l for l in txt.splitlines() if l.strip()]
print('bytes', len(t), 'lines', len(lines))
print('\n'.join(lines[-4:]))
