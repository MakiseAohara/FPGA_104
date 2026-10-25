#!/usr/bin/env python3
"""rec.py - record one scene with proper line buffering.

  python rec.py --variant NAME --scene S1_nobody --secs 35 [--port COM15]

Appends timestamped serial lines to log_v16_<NAME>.log and wraps them in
SEGMENT markers.  Complete lines only: a partial read is buffered until the
newline arrives, so MMT_OSD / MMT_IMG lines are never split.
"""
import argparse
import datetime as dt
import sys
import threading
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent

SCENE_DESC = {
    "S1_nobody": "nobody in frame",
    "S2_person_1m": "person ~1 m, facing camera",
    "S3_person_0p5m": "person ~0.5 m, facing camera",
}


def ts():
    return dt.datetime.now().isoformat(timespec="milliseconds")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--variant", required=True)
    ap.add_argument("--scene", required=True)
    ap.add_argument("--secs", type=float, default=35)
    ap.add_argument("--port", default="COM15")
    a = ap.parse_args()

    import serial

    log = HERE / ("log_v16_%s.log" % a.variant)
    desc = SCENE_DESC.get(a.scene, a.scene)
    fh = log.open("a", encoding="utf-8", newline="\n")
    stop = threading.Event()
    lines = [0]

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
                        txt = raw.decode("ascii", "replace").strip()
                        if txt:
                            fh.write("%s\t%s\n" % (ts(), txt))
                            lines[0] += 1
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
            fh.write("### ABORT %s no_firmware @ %s\n" % (a.scene, ts()))
            fh.close()
            print("ABORT: firmware not running -> reload needed")
            return 2
        t = threading.Thread(target=pump, args=(port,), daemon=True)
        t.start()
        fh.write("### SEGMENT VARIANT=%s | SCENE=%s | %s | secs=%d @ %s\n"
                 % (a.variant, a.scene, desc, a.secs, ts()))
        fh.flush()
        print("   >>> %s (%d s)  %s" % (a.scene, a.secs, desc))
        time.sleep(a.secs)
        stop.set()
        time.sleep(0.5)
        fh.write("### SCENE_END %s %s @ %s lines=%d\n"
                 % (a.variant, a.scene, ts(), lines[0]))
        fh.flush()
    fh.close()
    print("   <<< %s done, %d lines" % (a.scene, lines[0]))
    return 0


if __name__ == "__main__":
    sys.exit(main())
