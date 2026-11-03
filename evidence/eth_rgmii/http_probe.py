import socket, time
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.settimeout(5)
t0 = time.time()
try:
    s.connect(('169.254.47.62', 80))
    print('connect ok in %.2fs' % (time.time() - t0))
    s.sendall(b'GET / HTTP/1.1\r\nHost: 169.254.47.62\r\n\r\n')
    data = b''
    end = time.time() + 6
    while time.time() < end and len(data) < 6000:
        try:
            chunk = s.recv(2048)
        except socket.timeout:
            break
        if not chunk:
            break
        data += chunk
    print('got', len(data), 'bytes')
    print(data[:400].decode('utf-8', 'replace'))
except Exception as e:
    print('FAIL', repr(e))
finally:
    s.close()
