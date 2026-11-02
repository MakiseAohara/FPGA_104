import socket, time, sys
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(('0.0.0.0', 8080)); s.settimeout(1.0)
end = time.time() + float(sys.argv[1] if len(sys.argv) > 1 else 240)
n = 0
while time.time() < end:
    try:
        d, a = s.recvfrom(4096)
    except socket.timeout:
        continue
    n += 1
    if n <= 10 or n % 30 == 0:
        try:
            txt = d.decode('utf-8', 'replace').strip()
        except Exception:
            txt = d.hex()
        print('PKT %4d %s:%d len=%d  %s' % (n, a[0], a[1], len(d), txt), flush=True)
print('TOTAL', n, flush=True)
