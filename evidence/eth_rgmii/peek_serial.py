import serial, time
p = serial.Serial(None)
p.port = 'COM15'; p.dtr = False; p.rts = False
p.open(); p.timeout = 1
t = b''
end = time.time() + 3
while time.time() < end:
    t += p.read(4096)
p.close()
print('bytes', len(t))
print(t[-300:].decode('utf-8', 'replace'))
