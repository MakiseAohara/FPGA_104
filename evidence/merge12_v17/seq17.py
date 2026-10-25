#!/usr/bin/env python3
"""seq17.py - record the MERGE12 + v17 acceptance sequence.

  python seq17.py --phase quiet  --secs 120   # nobody, must be zero alarms
  python seq17.py --phase p1m    --secs 40    # person ~1 m
  python seq17.py --phase p05m   --secs 40    # person ~0.5 m
  python seq17.py --phase walk   --cycles 5 --gap 15   # walk-in x5

Every line is timestamped; SEGMENT / WALK markers let the alarm time be
correlated with each event.
"""
import argparse
import datetime as dt
import sys
import threading
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
LOG = HERE / "log_merge12_v17.log"
PREFIXES = ("MMT_", "###")


def ts():
    return dt.datetime.now().isoformat(timespec="milliseconds")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--phase", required=True,
                    choices=["quiet", "p1m", "p05m", "walk"])
    ap.add_argument("--secs", type=float, default=40)
    ap.add_argument("--cycles", type=int, default=5)
    ap.add_argument("--gap", type=float, default=15)
    ap.add_argument("--port", default="COM15")
    a = ap.parse_args()

    import serial

    fh = LOG.open("a", encoding="utf-8", newline="\n")
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
            fh.write("### PHASE walk cycles=%d gap=%d @ %s\n" % (a.cycles, a.gap, ts()))
            fh.flush()
            print("   >>> WALK phase: 5 walk-ins, one every %d s" % a.gap)
            for k in range(1, a.cycles + 1):
                fh.write("### WALK %d EXPECTED_ENTER @ %s\n" % (k, ts()))
                fh.flush()
                print("   >>> WALK %d  (enter now)" % k)
                time.sleep(a.gap)
        else:
            fh.write("### PHASE %s secs=%d @ %s\n" % (a.phase, a.secs, ts()))
            fh.flush()
            print("   >>> PHASE %s  (%d s)" % (a.phase, a.secs))
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
