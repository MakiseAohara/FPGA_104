#!/usr/bin/env python3
"""capture_v20.py - one continuous log: reset -> upload -> 30 min free capture.

The port is opened first and every line is timestamped into one file from the
very beginning, so MMT_BOOT / MMT_LIVE_BOOT / MMT_CFG / MMT_CAM / MMT_AE land in
the same log as the 30-minute capture.

Phase 1 (synchronous): flash the bitstream (= reset), wait for MMT_LOADER_READY,
upload the firmware with per-block retry x3, wait for MMT_LIVE_BOOT.
Phase 2 (threaded): keep logging for --secs; a silence > --gap writes one
`### GAP` line; on a serial error the port is reopened and a `### RECONNECT`
line is written (no re-flash).
"""
import argparse
import binascii
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


def ts():
    return dt.datetime.now().isoformat(timespec="milliseconds")


class Log:
    def __init__(self, path: Path):
        self.fh = path.open("a", encoding="utf-8", newline="\n")
        self.n = 0
        self.last = time.time()

    def line(self, text, stamp=True):
        if stamp:
            self.fh.write("%s\t%s\n" % (ts(), text))
        else:
            self.fh.write(text + "\n")
        self.fh.flush()
        self.n += 1
        self.last = time.time()

    def close(self):
        self.fh.close()


def flash_bit():
    cmd = ["powershell", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", str(FLASH),
           "-Bit", str(BIT), "-Sha256", BIT_SHA,
           "-EfinityHome", r"D:\Efinity\2026.1",
           "-ExpectedDriverVersion", "2.12.36.20",
           "-UsbUrl", "hiftdi://0x0403:0x6011/1",
           "-LogRoot", str(HERE / "_logs" / ("flash_" + dt.datetime.now().strftime("%H%M%S")))]
    import os
    env = os.environ.copy()
    env.pop("PYTHONHOME", None)
    env.update({
        "EFINITY_HOME": "D:/Efinity/2026.1",
        "EFXPGM_HOME": "D:/Efinity/2026.1/pgm",
        "EFXDBG_HOME": "D:/Efinity/2026.1/debugger",
        "EFXPT_HOME": "D:/Efinity/2026.1/pt",
        "EFXIPM_HOME": "D:/Efinity/2026.1/ipm",
        "EFINITY_USER_DIR": os.environ.get("LOCALAPPDATA", "").replace("\\", "/") + "/efinity",
        "EFX_HIFTDI_ENABLE": "1",
        "PYTHONHOME": "D:/Efinity/2026.1/python311",
        "PATH": "D:\\Efinity\\2026.1\\bin;D:\\Efinity\\2026.1\\python311\\bin;"
                + os.environ.get("PATH", ""),
    })
    env["EFINITY_USER_DIR_INI"] = env["EFINITY_USER_DIR"] + "/user_dir.ini"
    r = subprocess.run(cmd, capture_output=True, text=True, errors="replace", env=env)
    return r.returncode


class Reader:
    """Synchronous line reader used during the boot/upload phase."""

    def __init__(self, port, log: Log):
        self.port = port
        self.log = log
        self.buf = b""

    def line_until(self, tokens, timeout):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if b"\n" in self.buf:
                raw, self.buf = self.buf.split(b"\n", 1)
                txt = raw.decode("ascii", "replace").strip()
                if txt:
                    self.log.line(txt)
                    print("   |", txt[:100], flush=True)
                    if any(t in txt for t in tokens):
                        return txt
                    if "MMT_DDR_FAIL" in txt or "MMT_LOAD_FAIL" in txt:
                        raise RuntimeError(txt)
            else:
                chunk = self.port.read(max(1, self.port.in_waiting))
                self.buf += chunk
        raise TimeoutError("waiting %r" % (tokens,))


def upload(port, log: Log, image: Path):
    data = image.read_bytes()
    crc = binascii.crc32(data) & 0xFFFFFFFF
    r = Reader(port, log)
    r.line_until(["MMT_LOADER_READY"], 90)
    port.write(b"MMTL" + struct.pack("<II", len(data), crc))
    r.line_until(["MMT_LOAD_ACCEPT"], 5)
    for off in range(0, len(data), 64):
        blk = data[off:off + 64]
        port.write(blk)
        ack = b""
        for attempt in range(3):
            deadline = time.monotonic() + 6
            while time.monotonic() < deadline:
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
            raise IOError("block %d no ack after 3 tries" % (off // 64))
        if (off // 64) % 1500 == 0:
            print("      upload %d%%" % (off * 100 // len(data)), flush=True)
    r.line_until(["MMT_LOAD_PASS DDR_CRC"], 40)
    r.line_until(["MMT_LIVE_BOOT"], 30)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--image", required=True)
    ap.add_argument("--log", required=True)
    ap.add_argument("--secs", type=float, default=1800)
    ap.add_argument("--port", default="COM15")
    ap.add_argument("--gap", type=float, default=5.0)
    a = ap.parse_args()

    import serial

    log = Log(Path(a.log))
    log.line("### CAPTURE_START %s image=%s secs=%d" % (ts(), Path(a.image).name, a.secs),
             stamp=False)
    print("   >>> CAPTURE_START, opening port", flush=True)

    port = None
    for _ in range(15):
        try:
            port = serial.Serial(a.port, 115200, timeout=0.05, write_timeout=5)
            break
        except Exception:
            time.sleep(1.0)
    if port is None:
        print("ABORT: cannot open port")
        log.line("### ABORT cannot open port", stamp=False)
        log.close()
        return 3

    # ---- phase 1: reset (flash) then upload firmware, logging everything
    print("   >>> flashing bitstream (this resets the board)", flush=True)
    rc = flash_bit()
    log.line("### FLASH returncode=%d" % rc, stamp=False)
    if rc != 0:
        print("   flash failed")
        log.close()
        return 4
    try:
        upload(port, log, Path(a.image))
        print("   >>> firmware running", flush=True)
    except Exception as e:
        print("   upload failed:", e)
        log.line("### UPLOAD_FAIL %r" % (e,), stamp=False)
        log.close()
        return 5

    # ---- phase 2: free capture
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
                else:
                    log.line("### RECONNECT_FAIL", stamp=False)
                    time.sleep(2.0)

    th = threading.Thread(target=pump, daemon=True)
    th.start()
    tg = threading.Thread(target=watch_gap, daemon=True)
    tg.start()
    t0 = time.time()
    while time.time() - t0 < a.secs:
        time.sleep(2.0)
        el = int(time.time() - t0)
        if el and el % 300 < 2:
            print("      t=%4ds lines=%d gaps=%d reconn=%d"
                  % (el, log.n, st["gaps"], st["reconn"]), flush=True)
    stop.set()
    time.sleep(0.8)
    log.line("### CAPTURE_END lines=%d gaps=%d reconnects=%d"
             % (log.n, st["gaps"], st["reconn"]), stamp=False)
    log.close()
    print("   <<< done lines=%d gaps=%d reconn=%d" % (log.n, st["gaps"], st["reconn"]))
    return 0


if __name__ == "__main__":
    sys.exit(main())
