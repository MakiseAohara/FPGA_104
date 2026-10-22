"""Live person-detection readout.

Prints one compact line per second:

    p=  -93  b0m= 98  sat=  0  EMPTY     (last 12 frames: min -100 max -89)

Walk in and out of the frame and watch `p` and the verdict flip.

Accepts both firmware formats:
    MMT_EXP ... p100=<> p75=<> p50=<>      (v12 exposure probe)
    MMT_OSD ... p=<>                       (older builds)

Usage:
    python watch_p.py            # COM15
    python watch_p.py COM15 60   # port, seconds (0 = until Ctrl+C)
"""
import collections
import re
import sys
import time

import serial

PORT = sys.argv[1] if len(sys.argv) > 1 else "COM15"
SECS = float(sys.argv[2]) if len(sys.argv) > 2 else 0.0

RE_EXP = re.compile(r"b0m=(\d+)\s+sat=(\d+).*?p100=(-?\d+)")
RE_OSD = re.compile(r"\bp=(-?\d+).*?b0m=(\d+)")


def main():
    recent = collections.deque(maxlen=12)
    last = {"p": None, "b0m": None, "sat": None}
    total = pos = 0
    t0 = time.time()
    tprint = 0.0

    print(f"端口 {PORT}  115200   （Ctrl+C 结束）")
    print("空场应稳定在 p≈-90；人进画面后 p 应转正。\n")
    print(f"{'p':>6} {'b0m':>5} {'sat':>5}  {'判决':<6}  最近 12 帧")

    with serial.Serial(PORT, 115200, timeout=0.1) as ser:
        ser.reset_input_buffer()
        buf = bytearray()
        while True:
            if SECS and time.time() - t0 > SECS:
                break
            n = ser.in_waiting
            chunk = ser.read(n if n else 1)
            if chunk:
                buf.extend(chunk)
                while b"\n" in buf:
                    raw, tail = buf.split(b"\n", 1)
                    buf = bytearray(tail)
                    ln = raw.decode("ascii", "replace").strip()
                    m = RE_EXP.search(ln)
                    if m:
                        last["p"] = int(m.group(3))
                        last["b0m"] = int(m.group(1))
                        last["sat"] = int(m.group(2))
                    else:
                        m = RE_OSD.search(ln)
                        if not m:
                            continue
                        last["p"] = int(m.group(1))
                        last["b0m"] = int(m.group(2))
                        last["sat"] = None

                    recent.append(last["p"])
                    total += 1
                    if last["p"] > 0:
                        pos += 1

            now = time.time()
            if last["p"] is not None and now - tprint >= 1.0:
                tprint = now
                p = last["p"]
                verdict = "PERSON" if p > 0 else "EMPTY "
                sat = "-" if last["sat"] is None else str(last["sat"])
                tail = f"min {min(recent):4d}  max {max(recent):4d}"
                print(f"{p:>6} {last['b0m']:>5} {sat:>5}  {verdict:<6}  {tail}",
                      flush=True)

    if total:
        print(f"\n共 {total} 帧，判 PERSON {pos} 帧 ({100.0*pos/total:.1f}%)")


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        print("\n已停止")
