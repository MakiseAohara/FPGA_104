import socket, struct, sys, time
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("0.0.0.0", 8080)); s.settimeout(6.0)
t0 = time.time(); n = 0; kinds = {}
while time.time() - t0 < 12:
    try: d, a = s.recvfrom(4096)
    except socket.timeout: continue
    n += 1
    if len(d) >= 16:
        mg, ver, ty = d[0:2], d[2], d[3]
        eid, seq, tot, ts = struct.unpack(">IHHI", d[4:16])
        kinds[ty] = kinds.get(ty, 0) + 1
        if n <= 12: print("from %s len=%d magic=%s ver=%d type=%d eid=%d seq=%d/%d ts=%d body=%s" % (a[0], len(d), mg, ver, ty, eid, seq, tot, ts, d[16:24].hex()))
    else:
        print("short", len(d), d[:24].hex())
print("TOTAL", n, "types", kinds)
