import socket, struct, time
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("0.0.0.0", 8080)); s.settimeout(2.0)
sets, saved = {}, []
t0 = time.time()
while time.time() - t0 < 30 and len(saved) < 4:
    try:
        d, _ = s.recvfrom(4096)
    except socket.timeout:
        continue
    if len(d) < 16 or d[3] != 3:
        continue
    eid, seq, total, ts = struct.unpack(">IHHI", d[4:16])
    e = sets.setdefault(eid, {})
    e[seq] = d[16:]
    if len(e) == total and total > 0:
        try:
            buf = b"".join(e[i] for i in range(1, total + 1))
        except KeyError:
            continue
        saved.append(buf[:9216]); sets.pop(eid, None)
print("完整帧", len(saved))
for i, f in enumerate(saved):
    print(i, "mean %.1f min %d max %d" % (sum(f)/len(f), min(f), max(f)))
for i in range(1, len(saved)):
    a, b = saved[i-1], saved[i]
    diff = sum(1 for x, y in zip(a, b) if x != y)
    print("帧%d vs 帧%d 变化像素 %.1f%%" % (i-1, i, 100.0*diff/len(a)))
