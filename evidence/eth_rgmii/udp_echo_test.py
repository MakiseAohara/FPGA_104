import socket, time
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(('0.0.0.0', 8080))
s.settimeout(0.5)
# 先清空队列里的板子数据包
t = time.time()
while time.time() - t < 1.0:
    try: s.recvfrom(4096)
    except socket.timeout: pass
msg = b'PING-FROM-PC-1234567890'
s.sendto(msg, ('169.254.47.62', 8080))
print('SENT', len(msg), 'bytes to 169.254.47.62:8080')
end = time.time() + 6
got = []
while time.time() < end:
    try:
        d, a = s.recvfrom(4096)
    except socket.timeout:
        continue
    tag = 'ECHO' if msg[:8] in d else 'board'
    got.append((tag, len(d), d[:24].hex()))
    if len(got) >= 12: break
for g in got: print(g)
print('echo received:', any(g[0] == 'ECHO' for g in got))
