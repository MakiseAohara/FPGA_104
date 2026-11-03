import serial, time
p = serial.Serial(None); p.port='COM15'; p.baudrate=115200; p.dtr=False; p.rts=False
p.open(); p.timeout=0.4
t=b''
end=time.time()+4
while time.time()<end: t += p.read(8192)
p.close()
txt=t.decode('utf-8','replace')
for k in ('MMT_GE','MMT_LP ','MMT_DEC'):
    ls=[l for l in txt.splitlines() if l.startswith(k)]
    print(k, len(ls), ls[-1][:120] if ls else '')
