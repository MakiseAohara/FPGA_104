import socket, time
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.settimeout(8)
t0 = time.time()
try:
    s.connect(('169.254.47.62', 80))
    print('connect OK %.2fs' % (time.time()-t0))
    s.sendall(b'GET / HTTP/1.1\r\nHost: 169.254.47.62\r\nConnection: close\r\n\r\n')
    data = b''
    end = time.time()+8
    while time.time() < end and len(data) < 8000:
        try:
            c = s.recv(4096)
        except socket.timeout:
            break
        if not c: break
        data += c
    print('got', len(data))
    print(data[:300].decode('utf-8','replace'))
except Exception as e:
    print('FAIL', repr(e))
finally:
    s.close()
