#!/usr/bin/env python3
"""seq18.py - MERGE14 + v18 acceptance capture.

  python seq18.py --phase health --secs 60
  python seq18.py --phase quiet  --secs 120
  python seq18.py --phase p1m    --secs 40
  python seq18.py --phase p05m   --secs 40
  python seq18.py --phase walk   --cycles 5 --stand 8 --gap 15
"""
import argparse
import datetime as dt
import sys
import threading
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
LOG = HERE / "log_merge14_v18.log"


def ts():
    return dt.datetime.now().isoformat(timespec="milliseconds")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--phase", required=True,
                    choices=["health", "quiet", "p1m", "p05m", "walk"])
    ap.add_argument("--secs", type=float, default=40)
    ap.add_argument("--cycles", type=int, default=5)
    ap.add_argument("--stand", type=float, default=8)
    ap.add_argument("--gap", type=float, default=15)
    ap.add_argument("--port", default="COM15")
    ap.add_argument("--log", default=str(LOG))
    a = ap.parse_args()

    import serial

    fh = Path(a.log).open("a", encoding="utf-8", newline="\n")
    stop = threading.Event()
    count = [0]

    def pump(port):
        buf = b""
        while not stop.is_set():
            try:
                n = port.in_waiting
                data = port.read(n) if n else b""
                if data:
                    buf += data
                    while b"\n" in buf:
                        raw, buf = buf.split(b"\n", 1)
                        t = raw.decode("ascii", "replace").strip()
                        if t:
                            fh.write("%s\t%s\n" % (ts(), t))
                            count[0] += 1
                    fh.flush()
                else:
                    time.sleep(0.01)
            except Exception:
                break

    port = None
    for _ in range(12):
        try:
            port = serial.Serial(a.port, 115200, timeout=0.1)
            break
        except Exception:
            time.sleep(1.0)
    if port is None:
        print("ABORT: cannot open", a.port)
        fh.close()
        return 3

    with port:
        port.reset_input_buffer()
        probe = b""
        t0 = time.time()
        while time.time() - t0 < 6.0:
            probe += port.read(max(1, port.in_waiting))
        if (probe.count(b"MMT_OSD") + probe.count(b"MMT_DEC")) < 1:
            fh.write("### ABORT no_firmware @ %s\n" % ts())
            fh.close()
            print("ABORT: firmware not running")
            return 2
        th = threading.Thread(target=pump, args=(port,), daemon=True)
        th.start()

        if a.phase == "walk":
            fh.write("### PHASE walk cycles=%d stand=%d gap=%d @ %s\n"
                     % (a.cycles, a.stand, a.gap, ts()))
            fh.flush()
            print("   >>> WALK: %d cycles, stand %ds, every %ds"
                  % (a.cycles, a.stand, a.gap))
            for k in range(1, a.cycles + 1):
                fh.write("### WALK %d ENTER @ %s\n" % (k, ts()))
                fh.flush()
                print("   >>> WALK %d ENTER (walk in now)" % k)
                time.sleep(a.stand)
                fh.write("### WALK %d LEAVE @ %s\n" % (k, ts()))
                fh.flush()
                print("   <<< WALK %d LEAVE (walk out now)" % k)
                time.sleep(max(0.0, a.gap - a.stand))
        else:
            fh.write("### PHASE %s secs=%d @ %s\n" % (a.phase, a.secs, ts()))
            fh.flush()
            print("   >>> PHASE %s (%d s)" % (a.phase, a.secs))
            time.sleep(a.secs)

        stop.set()
        time.sleep(0.5)
        fh.write("### PHASE_END %s lines=%d @ %s\n" % (a.phase, count[0], ts()))
        fh.flush()
    fh.close()
    print("   <<< %s done, %d lines" % (a.phase, count[0]))
    return 0


if __name__ == "__main__":
    sys.exit(main())
