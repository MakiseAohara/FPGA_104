import serial, time, sys, pathlib
out = pathlib.Path(r'out\mot_test'); out.mkdir(parents=True, exist_ok=True)
dur = float(sys.argv[1]) if len(sys.argv) > 1 else 150
p = serial.Serial(None); p.port='COM15'; p.baudrate=115200; p.dtr=False; p.rts=False
p.open(); p.timeout=0.4
f = open(out / 'serial_ts.log', 'w', encoding='utf-8')
t0 = time.time()
buf = b''
last_mark = 0
print('CAPTURE START', flush=True)
while time.time() - t0 < dur:
    buf += p.read(8192)
    while b'\n' in buf:
        line, buf = buf.split(b'\n', 1)
        s = line.decode('utf-8', 'replace').strip()
        if not s: continue
        t = time.time() - t0
        f.write('%.2f\t%s\n' % (t, s))
        if s.startswith('MMT_MOT'):
            m = int(t // 15)
            if m != last_mark:
                last_mark = m
                print('MARK %3ds' % (m * 15), flush=True)
f.close(); p.close()
print('CAPTURE DONE', flush=True)
