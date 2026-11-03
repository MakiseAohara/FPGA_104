import serial, threading, time, socket
buf = []
def reader():
    p = serial.Serial(None); p.port='COM15'; p.baudrate=115200; p.dtr=False; p.rts=False
    p.open(); p.timeout=0.3
    end = time.time()+7
    while time.time() < end: buf.append(p.read(8192))
    p.close()
th = threading.Thread(target=reader); th.start()
time.sleep(1.2)
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1); s.settimeout(0.5)
for i in range(3):
    s.sendto(b'HELLO-FROM-PC-%d' % i, ('169.254.47.62', 8080))
    time.sleep(0.4)
s.close()
th.join()
t = b''.join(buf).decode('utf-8','replace')
lines = [l for l in t.splitlines() if 'MMT_GE' in l]
print('GE lines', len(lines))
for l in lines[-3:]: print(l.strip())
