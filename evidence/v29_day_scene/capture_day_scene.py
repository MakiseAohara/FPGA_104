#!/usr/bin/env python3
"""capture_day_scene.py - MERGE15 + v29 daycap firmware, segments A-G.

Flashes MERGE15 (reset), uploads the day-capture firmware, then walks the
A..G schedule. Each boundary writes a host-side `MMT_MARK seg=X edge=START|END`
line (the firmware itself is unchanged apart from the dump rate / DAY preset),
plus a wall-clock record in segment_events.csv.
"""
import binascii
import csv
import datetime as dt
import json
import os
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
BIT = Path(r"C:\Users\Makise Aohara\Documents\Codex\2026-10-26\yo\work"
           r"\FPGA_104-main\evidence\v27_rtl_ir\v7_MERGE15.bit")
BIT_SHA = "74E205F84613F23C1DD8040E2CF31F032BBF524D3ED81022DE551D998613AF40"

# (label, seconds, what the operator does)
PLAN = [
    ("A", 120, "空场：室友照常在座，其他人离开画面，不动任何东西"),
    ("B", 120, "正脸走动：在画面里走动、转身，正对镜头"),
    ("C", 120, "侧脸 / 低头 / 看手机"),
    ("D", 120, "只露半个头或肩膀，站在画面边缘"),
    ("E", 120, "进出交替：每次进出间隔 5~10 秒"),
    ("F", 150, "站定 3 次：走进站 30 秒→离开→空场 20 秒，循环 3 次"),
    ("G", 120, "空场：确认 ir_solo 不误报"),
]


def ts():
    return dt.datetime.now().isoformat(timespec="milliseconds")


class Log:
    def __init__(self, path: Path):
        self.fh = path.open("a", encoding="utf-8", newline="\n")
        self.n = 0
        self.last = time.time()
        self.last_dec_t = 0
        self.first_mean = []

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
        if "mean_sensor=" in text and len(self.first_mean) < 20:
            try:
                self.first_mean.append(int(text.split("mean_sensor=")[1].split()[0]))
            except Exception:
                pass


def flash_bit():
    env = os.environ.copy()
    env.update({
        "EFINITY_HOME": "D:/Efinity/2026.1", "EFXPGM_HOME": "D:/Efinity/2026.1/pgm",
        "EFXDBG_HOME": "D:/Efinity/2026.1/debugger", "EFXPT_HOME": "D:/Efinity/2026.1/pt",
        "EFXIPM_HOME": "D:/Efinity/2026.1/ipm",
        "EFINITY_USER_DIR": os.environ.get("LOCALAPPDATA", "").replace("\\", "/") + "/efinity",
        "EFX_HIFTDI_ENABLE": "1", "PYTHONHOME": "D:/Efinity/2026.1/python311",
        "PATH": "D:\\Efinity\\2026.1\\bin;D:\\Efinity\\2026.1\\python311\\bin;" + env.get("PATH", ""),
    })
    env["EFINITY_USER_DIR_INI"] = env["EFINITY_USER_DIR"] + "/user_dir.ini"
    cmd = ["powershell", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", str(FLASH),
           "-Bit", str(BIT), "-Sha256", BIT_SHA, "-EfinityHome", r"D:\Efinity\2026.1",
           "-ExpectedDriverVersion", "2.12.36.20", "-UsbUrl", "hiftdi://0x0403:0x6011/1",
           "-LogRoot", str(HERE / "_logs" / ("flash_" + dt.datetime.now().strftime("%H%M%S")))]
    return subprocess.run(cmd, capture_output=True, text=True, errors="replace", env=env).returncode


class Reader:
    def __init__(self, port, log):
        self.port, self.log, self.buf = port, log, b""

    def until(self, tokens, timeout):
        end = time.monotonic() + timeout
        while time.monotonic() < end:
            if b"\n" in self.buf:
                raw, self.buf = self.buf.split(b"\n", 1)
                t = raw.decode("ascii", "replace").strip()
                if t:
                    self.log.line(t)
                    print("   |", t[:95], flush=True)
                    if any(k in t for k in tokens):
                        return t
            else:
                self.buf += self.port.read(max(1, self.port.in_waiting))
        raise TimeoutError(str(tokens))


def upload(port, log, image: Path):
    data = image.read_bytes()
    r = Reader(port, log)
    r.until(["MMT_LOADER_READY"], 90)
    port.write(b"MMTL" + struct.pack("<II", len(data), binascii.crc32(data) & 0xFFFFFFFF))
    r.until(["MMT_LOAD_ACCEPT"], 6)
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
    r.until(["MMT_LOAD_PASS DDR_CRC"], 40)
    r.until(["MMT_LIVE_BOOT"], 40)


def main():
    import serial

    image = HERE / "tinyml_pdti8_v29_daycap.bin"
    log = Log(HERE / "log_v29_day_scene.log")
    log.line("### CAPTURE_START %s image=%s bit=MERGE15" % (ts(), image.name), stamp=False)
    events = []

    port = None
    for _ in range(15):
        try:
            port = serial.Serial("COM15", 115200, timeout=0.05, write_timeout=5)
            break
        except Exception:
            time.sleep(1.0)
    if port is None:
        log.line("### ABORT no COM15", stamp=False)
        return 3

    print("   >>> flash MERGE15", flush=True)
    if flash_bit() != 0:
        log.line("### FLASH_FAIL", stamp=False)
        return 4
    print("   >>> upload firmware", flush=True)
    try:
        upload(port, log, image)
    except Exception as e:
        log.line("### UPLOAD_FAIL %r" % (e,), stamp=False)
        print("   upload failed:", e)
        return 5

    st = {"gaps": 0, "reconn": 0}
    stop = threading.Event()
    cur = {"port": port}

    def pump():
        buf = b""
        while not stop.is_set():
            try:
                n = cur["port"].in_waiting
                d = cur["port"].read(n) if n else b""
                if d:
                    buf += d
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
                        cur["port"] = serial.Serial("COM15", 115200, timeout=0.05,
                                                    write_timeout=5)
                        buf = b""
                        st["reconn"] += 1
                        log.line("### RECONNECTED ok=%d" % st["reconn"], stamp=False)
                        break
                    except Exception:
                        time.sleep(1.0)

    def gapwatch():
        while not stop.is_set():
            time.sleep(0.2)
            if time.time() - log.last > 5.0:
                log.line("### GAP idle=%.1fs" % (time.time() - log.last), stamp=False)
                st["gaps"] += 1

    threading.Thread(target=pump, daemon=True).start()
    threading.Thread(target=gapwatch, daemon=True).start()

    # boot readout: decide DAY / NIGHT from the first mean_sensor samples
    time.sleep(8)
    ms = sorted(log.first_mean)[len(log.first_mean) // 2] if log.first_mean else 0
    preset = "DAY" if ms > 130 or ms >= 60 else "NIGHT"
    log.line("### PRESET_DECISION name=%s boot_mean_sensor=%d rule='>130 DAY, <60 NIGHT, else DAY'"
             % (preset, ms), stamp=False)
    print("   boot mean_sensor=%d -> preset=%s" % (ms, preset), flush=True)

    for seg, secs, note in PLAN:
        wall = ts()
        log.line("MMT_MARK seg=%s edge=START ms=%d wall=%s note=%s"
                 % (seg, log.last_dec_t, wall, note), stamp=False)
        events.append(dict(seg=seg, edge="START", wall=wall, device_ms=log.last_dec_t))
        print("   ### %s START %s (%ds) %s" % (seg, wall, secs, note), flush=True)
        if seg == "F":
            for k in range(3):
                time.sleep(30)
                w2 = ts()
                log.line("MMT_MARK seg=F edge=STAND%d ms=%d wall=%s" % (k + 1, log.last_dec_t, w2),
                         stamp=False)
                events.append(dict(seg="F%d" % (k + 1), edge="STAND", wall=w2,
                                   device_ms=log.last_dec_t))
                print("   ### F 站定 %d 结束，请离开画面（空场 20 秒）" % (k + 1), flush=True)
                time.sleep(20)
        else:
            time.sleep(secs)
        wall = ts()
        log.line("MMT_MARK seg=%s edge=END ms=%d wall=%s" % (seg, log.last_dec_t, wall), stamp=False)
        events.append(dict(seg=seg, edge="END", wall=wall, device_ms=log.last_dec_t))
        print("   ### %s END %s" % (seg, wall), flush=True)

    stop.set()
    time.sleep(1.0)
    log.line("### CAPTURE_END lines=%d gaps=%d reconnects=%d" % (log.n, st["gaps"], st["reconn"]),
             stamp=False)
    log.close()
    with (HERE / "segment_events.csv").open("w", newline="", encoding="utf-8-sig") as fh:
        w = csv.DictWriter(fh, fieldnames=["seg", "edge", "wall", "device_ms"])
        w.writeheader()
        w.writerows(events)
    print("   <<< done lines=%d gaps=%d reconn=%d" % (log.n, st["gaps"], st["reconn"]))
    return 0


if __name__ == "__main__":
    sys.exit(main())
