import serial, time
for port in ('COM13','COM14','COM15','COM16'):
    try:
        p = serial.Serial(None); p.port = port; p.dtr=False; p.rts=False
        p.open(); p.timeout=0.4
        t = b''
        end = time.time()+1.5
        while time.time()<end: t += p.read(4096)
        p.close()
        txt = t.decode('utf-8','replace')
        printable = sum(1 for c in txt if 32 <= ord(c) < 127)
        print('%-6s bytes=%-5d printable=%d  %s' % (port, len(t), printable, txt[:60].replace('\n','|')))
    except Exception as e:
        print(port, 'ERR', str(e)[:60])
