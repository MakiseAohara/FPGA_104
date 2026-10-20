"""Watch the live inference output for N seconds and summarise it.

Usage:
    <efinity-python> watch_live.py 30

It prints every MMT_LIVE line it sees and a short summary at the end, so you can
stand in front of the camera and see whether the verdict flips to PERSON.
"""
import sys
import time

import serial

secs = float(sys.argv[1]) if len(sys.argv) > 1 else 30.0
port = sys.argv[2] if len(sys.argv) > 2 else "COM15"

buf = bytearray()
lines = []
with serial.Serial(port, 115200, timeout=0.1) as p:
    p.reset_input_buffer()
    t0 = time.time()
    while time.time() - t0 < secs:
        n = p.in_waiting
        chunk = p.read(n if n else 1)
        if not chunk:
            continue
        buf.extend(chunk)
        while b"\n" in buf:
            line, tail = buf.split(b"\n", 1)
            buf = bytearray(tail)
            t = line.decode("ascii", "replace").strip()
            if "MMT_LIVE" in t and " f=" in t:
                lines.append(t)
                print(t, flush=True)

print("\n--- summary ---")
print("frames seen:", len(lines))
person = empty = 0
for t in lines:
    try:
        if " v=" in t:
            pv = int(t.split(" v=")[1].split()[0])
        else:
            pv = int(t.split("person=")[1].split()[0])
    except Exception:
        continue
    if pv > 0:
        person += 1
    else:
        empty += 1
print("verdict PERSON:", person, " EMPTY:", empty)
if lines:
    print("first:", lines[0])
    print("last :", lines[-1])

