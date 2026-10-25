#!/usr/bin/env python3
"""capture_v22.py - v19 gate capture with an ENTER/LEAVE schedule.

Timeline (after a boot + prep delay):
    IDLE 30 s  ->  6 x [ ENTER (walk in) | STAND 20 s | LEAVE (walk out) | IDLE 30 s ]
    -> IDLE 60 s

Every action writes `### EVT <name> wall=<iso>` into the log and a row into
script_events.csv with the nearest MMT_DEC device_ms seen so far.
"""
import argparse
import binascii
import csv
import datetime as dt
import struct
import subprocess
import sys
import threading
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
FLASH = Path(r"C:\Users\Makise Aohara\Documents\Codex\2026-10-15"
             r"\https-github-com-makiseaohara-fpga-104\outputs"
             r"\fpga_onboard_verified_20261020\tools\flash_vendor.ps1")
BIT = HERE / "v7_MERGE14.bit"
BIT_SHA = "E399F99067E6544262315607B27FC3DD2394F37FD245F909DEE1EBA8A8B41FE8"

IDLE0 = 30
STAND = 20
IDLE = 30
ROUNDS = 6
IDLE_END = 60
PREP = 40


def ts():
    return dt.datetime.now().isoformat(timespec="milliseconds")


class Log:
    def __init__(self, path: Path):
        self.fh = path.open("a", encoding="utf-8", newline="\n")
        self.n = 0
        self.last = time.time()
        self.last_dec_t = 0

    def line(self, text, stamp=True):
        if stamp:
            self.fh.write("%s\t%s\n" % (ts(), text))
        else:
            self.fh.write(text + "\n")
        self.fh.flush()
        self.n += 1
        self.last = time.time()
        if "MMT_DEC t=" in text:
            try:
                self.last_dec_t = int(text.split("t=")[1].split()[0])
            except Exception:
                pass

    def close(self):
        self.fh.close()


def flash_bit():
    import os
    cmd = ["powershell", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", str(FLASH),
           "-Bit", str(BIT), "-Sha256", BIT_SHA,
           "-EfinityHome", r"D:\Efinity\2026.1",
           "-ExpectedDriverVersion", "2.12.36.20",
           "-UsbUrl", "hiftdi://0x0403:0x6011/1",
           "-LogRoot", str(HERE / "_logs" / ("flash_" + dt.datetime.now().strftime("%H%M%S")))]
    env = os.environ.copy()
    env.pop("PYTHONHOME", None)
    env.update({
        "EFINITY_HOME": "D:/Efinity/2026.1", "EFXPGM_HOME": "D:/Efinity/2026.1/pgm",
        "EFXDBG_HOME": "D:/Efinity/2026.1/debugger", "EFXPT_HOME": "D:/Efinity/2026.1/pt",
        "EFXIPM_HOME": "D:/Efinity/2026.1/ipm",
        "EFINITY_USER_DIR": os.environ.get("LOCALAPPDATA", "").replace("\\", "/") + "/efinity",
        "EFX_HIFTDI_ENABLE": "1", "PYTHONHOME": "D:/Efinity/2026.1/python311",
        "PATH": "D:\\Efinity\\2026.1\\bin;D:\\Efinity\\2026.1\\python311\\bin;"
                + os.environ.get("PATH", ""),
    })
    env["EFINITY_USER_DIR_INI"] = env["EFINITY_USER_DIR"] + "/user_dir.ini"
    return subprocess.run(cmd, capture_output=True, text=True, errors="replace", env=env).returncode


class Reader:
    def __init__(self, port, log):
        self.port, self.log, self.buf = port, log, b""

    def line_until(self, tokens, timeout):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if b"\n" in self.buf:
                raw, self.buf = self.buf.split(b"\n", 1)
                txt = raw.decode("ascii", "replace").strip()
                if txt:
                    self.log.line(txt)
                    print("   |", txt[:95], flush=True)
                    if any(t in txt for t in tokens):
                        return txt
            else:
                self.buf += self.port.read(max(1, self.port.in_waiting))
        raise TimeoutError("waiting %r" % (tokens,))


def upload(port, log, image):
    data = image.read_bytes()
    r = Reader(port, log)
    r.line_until(["MMT_LOADER_READY"], 90)
    port.write(b"MMTL" + struct.pack("<II", len(data), binascii.crc32(data) & 0xFFFFFFFF))
    r.line_until(["MMT_LOAD_ACCEPT"], 5)
    for off in range(0, len(data), 64):
        blk = data[off:off + 64]
        port.write(blk)
        ack = b""
        for attempt in range(3):
            dl = time.monotonic() + 6
            while time.monotonic() < dl:
                c = port.read(1)
                if not c:
                    continue
                if c == b"\x06":
                    ack = c
                    break
            if ack == b"\x06":
                break
            if attempt < 2:
                port.write(blk)
        if ack != b"\x06":
            raise IOError("block %d no ack" % (off // 64))
    r.line_until(["MMT_LOAD_PASS DDR_CRC"], 40)
    r.line_until(["MMT_LIVE_BOOT"], 30)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--image", required=True)
    ap.add_argument("--log", required=True)
    ap.add_argument("--port", default="COM15")
    ap.add_argument("--gap", type=float, default=5.0)
    a = ap.parse_args()

    import serial

    log = Log(Path(a.log))
    events = []
    log.line("### CAPTURE_START %s image=%s" % (ts(), Path(a.image).name), stamp=False)

    port = None
    for _ in range(15):
        try:
            port = serial.Serial(a.port, 115200, timeout=0.05, write_timeout=5)
            break
        except Exception:
            time.sleep(1.0)
    if port is None:
        log.line("### ABORT no port", stamp=False)
        return 3

    print("   >>> flash + upload", flush=True)
    if flash_bit() != 0:
        log.line("### FLASH_FAIL", stamp=False)
        return 4
    try:
        upload(port, log, Path(a.image))
    except Exception as e:
        log.line("### UPLOAD_FAIL %r" % (e,), stamp=False)
        print("   upload failed:", e)
        return 5
    print("   >>> firmware up", flush=True)

    stop = threading.Event()
    st = {"gaps": 0, "reconn": 0}
    cur = {"port": port}

    def watch_gap():
        while not stop.is_set():
            time.sleep(0.2)
            if time.time() - log.last > a.gap:
                log.line("### GAP idle=%.1fs" % (time.time() - log.last), stamp=False)
                st["gaps"] += 1

    def pump():
        buf = b""
        while not stop.is_set():
            try:
                n = cur["port"].in_waiting
                data = cur["port"].read(n) if n else b""
                if data:
                    buf += data
                    while b"\n" in buf:
                        raw, buf = buf.split(b"\n", 1)
                        t = raw.decode("ascii", "replace").strip()
                        if t:
                            log.line(t)
                else:
                    time.sleep(0.01)
            except Exception as e:
                log.line("### RECONNECT_TRY %r" % (e,), stamp=False)
                try:
                    cur["port"].close()
                except Exception:
                    pass
                for _ in range(20):
                    try:
                        cur["port"] = serial.Serial(a.port, 115200, timeout=0.05,
                                                    write_timeout=5)
                        buf = b""
                        st["reconn"] += 1
                        log.line("### RECONNECTED ok=%d" % st["reconn"], stamp=False)
                        break
                    except Exception:
                        time.sleep(1.0)

    threading.Thread(target=pump, daemon=True).start()
    threading.Thread(target=watch_gap, daemon=True).start()

    def evt(name, note=""):
        wall = ts()
        log.line("### EVT %s %s wall=%s" % (name, note, wall), stamp=False)
        events.append({"event": name, "wall": wall, "device_ms": log.last_dec_t,
                       "note": note})
        print("   ### %-10s wall=%s dev_ms=%d" % (name, wall, log.last_dec_t), flush=True)

    print("   >>> prep %d s" % PREP, flush=True)
    time.sleep(PREP)

    evt("IDLE0", "empty 30s")
    time.sleep(IDLE0)
    for k in range(1, ROUNDS + 1):
        evt("ENTER%d" % k, "walk in")
        time.sleep(STAND)
        evt("LEAVE%d" % k, "walk out")
        time.sleep(IDLE)
    evt("IDLE_END", "empty 60s")
    time.sleep(IDLE_END)

    stop.set()
    time.sleep(0.8)
    log.line("### CAPTURE_END lines=%d gaps=%d reconnects=%d"
             % (log.n, st["gaps"], st["reconn"]), stamp=False)
    log.close()

    with (HERE / "script_events.csv").open("w", newline="", encoding="utf-8-sig") as fh:
        w = csv.DictWriter(fh, fieldnames=["event", "wall", "device_ms", "note"])
        w.writeheader()
        for e in events:
            w.writerow(e)
    print("   <<< done lines=%d gaps=%d reconn=%d events=%d"
          % (log.n, st["gaps"], st["reconn"], len(events)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
