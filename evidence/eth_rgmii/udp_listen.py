import socket, time, sys
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
s.bind(('0.0.0.0', 8080))
s.settimeout(1.0)
end = time.time() + 90
n = 0
print('LISTEN 0.0.0.0:8080', flush=True)
while time.time() < end:
    try:
        d, a = s.recvfrom(4096)
    except socket.timeout:
        continue
    n += 1
    if n <= 8 or n % 20 == 0:
        print('PKT %d from %s:%d len=%d %s' % (n, a[0], a[1], len(d), d[:16].hex()), flush=True)
print('TOTAL', n, flush=True)
