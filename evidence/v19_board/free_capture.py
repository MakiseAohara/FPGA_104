#!/usr/bin/env python3
"""free_capture.py - continuous serial capture, no phase timing.

  python free_capture.py --secs 600 --log log_v19_A_dump.log

One reader thread; every serial line is written with a host timestamp.
A silence longer than --gap seconds writes a single `### GAP` line and the
capture keeps going (it never stops on an idle line).
"""
import argparse
import datetime as dt
import sys
import threading
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent


def ts():
    return dt.datetime.now().isoformat(timespec="milliseconds")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--secs", type=float, default=600)
    ap.add_argument("--log", required=True)
    ap.add_argument("--port", default="COM15")
    ap.add_argument("--gap", type=float, default=5.0)
    a = ap.parse_args()

    import serial

    fh = Path(a.log).open("a", encoding="utf-8", newline="\n")
    fh.write("### CAPTURE_START %s secs=%d gap=%d\n" % (ts(), a.secs, a.gap))
    fh.flush()

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

    stop = threading.Event()
    state = {"lines": 0, "gaps": 0, "last": time.time()}

    def watch_gap():
        while not stop.is_set():
            time.sleep(0.2)
            if time.time() - state["last"] > a.gap:
                fh.write("### GAP %s idle=%.1fs\n"
                         % (ts(), time.time() - state["last"]))
                fh.flush()
                state["gaps"] += 1
                state["last"] = time.time()

    def pump():
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
                            state["lines"] += 1
                            state["last"] = time.time()
                    fh.flush()
                else:
                    time.sleep(0.01)
            except Exception:
                break

    with port:
        port.reset_input_buffer()
        th = threading.Thread(target=pump, daemon=True)
        th.start()
        tg = threading.Thread(target=watch_gap, daemon=True)
        tg.start()
        t0 = time.time()
        print("   >>> FREE CAPTURE %d s -> %s" % (a.secs, Path(a.log).name),
              flush=True)
        while time.time() - t0 < a.secs:
            time.sleep(1.0)
            if int(time.time() - t0) % 60 == 0:
                print("       t=%3ds lines=%d gaps=%d"
                      % (time.time() - t0, state["lines"], state["gaps"]),
                      flush=True)
        stop.set()
        time.sleep(0.6)
    fh.write("### CAPTURE_END %s lines=%d gaps=%d\n"
             % (ts(), state["lines"], state["gaps"]))
    fh.close()
    print("   <<< done lines=%d gaps=%d" % (state["lines"], state["gaps"]))
    return 0


if __name__ == "__main__":
    sys.exit(main())
