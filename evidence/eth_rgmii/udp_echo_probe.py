import socket, time, sys
# 发一个 UDP 包给板子，等 "MMT-ECH" 回来
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(('0.0.0.0', 8080)); s.settimeout(0.5)
t0 = time.time()
while time.time() - t0 < 1.0:
    try: s.recvfrom(2048)
    except socket.timeout: pass
msg = b'PING' + str(int(time.time()) % 10000).encode()
s.sendto(msg, ('169.254.47.62', 8080))
print('sent', msg)
end = time.time() + 6
hit = False
while time.time() < end:
    try:
        d, a = s.recvfrom(2048)
    except socket.timeout:
        continue
    if d.startswith(b'MMT-ECH'):
        print('ECHO from', a[0], ':', a[1], 'len', len(d), d)
        hit = True
        break
print('echo ok' if hit else 'no echo')
