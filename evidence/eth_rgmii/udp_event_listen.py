import socket, time, sys, struct, collections
dur = float(sys.argv[1]) if len(sys.argv) > 1 else 45
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(('0.0.0.0', 8080)); s.settimeout(0.5)
print('LISTEN 8080 for %.0fs' % dur, flush=True)
t0 = time.time()
cnt = collections.Counter(); evs = []; hb_ts = []; thumb = {}
end = t0 + dur
while time.time() < end:
    try: d, a = s.recvfrom(2048)
    except socket.timeout: continue
    if len(d) < 16 or d[0] != 0x4D or d[1] != 0x54:
        cnt['bad'] += 1; continue
    typ = d[3]
    evid, seq, total, ms = struct.unpack('>IHHI', d[4:16])
    body = d[16:]
    cnt[typ] += 1
    if typ == 1:
        evs.append((time.time()-t0, evid, body[0], body[1], body[2], body[3], body[4], body[5]))
    elif typ == 2:
        hb_ts.append(time.time()-t0)
    elif typ == 3:
        thumb.setdefault(evid, {})[seq] = body
s.close()
print('counts by type:', dict(cnt), flush=True)
if hb_ts:
    gaps = [round(hb_ts[i+1]-hb_ts[i],2) for i in range(len(hb_ts)-1)]
    print('heartbeats: %d, gap mean %.2fs min %.2f max %.2f' % (len(hb_ts), sum(gaps)/len(gaps), min(gaps), max(gaps)), flush=True)
for e in evs[:12]:
    print('EVENT t=%.1fs id=%d ev=%d x=%d y=%d conf=%d obs=%d nd=%d' % e, flush=True)
for k, v in thumb.items():
    tot = max(v) + 1 if v else 0
    print('THUMB evid=%d chunks=%d got=%d complete=%s' % (k, tot, len(v), len(v) == tot), flush=True)
