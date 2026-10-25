#!/usr/bin/env python3
"""variant_ctl.py - decouple firmware loading from scene recording.

  python variant_ctl.py load   --image tinyml_pdti8_v16_base_dump.bin
  python variant_ctl.py record --variant base_dump

`load` starts the loader, flashes the bitstream, waits for MMT_LIVE_BOOT and
retries flash+upload up to N times (the DDR upload is flaky).  On success it
stops the host loader so COM15 is free; the firmware keeps running on the board.

`record` opens the serial port itself, appends every line with a host timestamp
to log_v16_<variant>.log and inserts the three SEGMENT markers.
"""
from __future__ import annotations

import argparse
import datetime as dt
import os
import subprocess
import sys
import threading
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
LOADER_PY = r"D:\Efinity\2026.1\python311\bin\python.exe"
LOADER = HERE / "tools" / "load_and_run.py"
FLASH = Path(r"C:\Users\Makise Aohara\Documents\Codex\2026-10-15"
             r"\https-github-com-makiseaohara-fpga-104\outputs"
             r"\fpga_onboard_verified_20261020\tools\flash_vendor.ps1")
BIT = HERE / "v7_MERGE11.bit"
BIT_SHA = "E399F99067E6544262315607B27FC3DD2394F37FD245F909DEE1EBA8A8B41FE8"

SCENES = [("S1_nobody", "nobody in frame", 35),
          ("S2_person_1m", "person ~1 m, facing camera", 35),
          ("S3_person_0p5m", "person ~0.5 m, facing camera", 35)]


def ts() -> str:
    return dt.datetime.now().isoformat(timespec="milliseconds")


def flash_bit() -> int:
    cmd = ["powershell", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", str(FLASH),
           "-Bit", str(BIT), "-Sha256", BIT_SHA,
           "-EfinityHome", r"D:\Efinity\2026.1",
           "-ExpectedDriverVersion", "2.12.36.20",
           "-UsbUrl", "hiftdi://0x0403:0x6011/1",
           "-LogRoot", str(HERE / "_logs" / ("flash_" + dt.datetime.now().strftime("%H%M%S")))]
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


def cmd_load(a) -> int:
    img = HERE / a.image
    name = img.stem
    log = HERE / ("log_v16_%s.log" % name)
    for attempt in range(1, a.attempts + 1):
        print("=== attempt %d/%d  %s" % (attempt, a.attempts, name), flush=True)
        fh = log.open("a", encoding="utf-8", newline="\n")
        fh.write("### HOST_T0 %s attempt=%d image=%s\n" % (ts(), attempt, a.image))
        fh.flush()
        env = os.environ.copy()
        env["PYTHONHOME"] = r"D:/Efinity/2026.1/python311"
        proc = subprocess.Popen(
            [LOADER_PY, str(LOADER), "--port", a.port, "--image", str(img),
             "--out", str(HERE / "_runs" / name),
             "--boot-timeout", "45", "--run-timeout", "900"],
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
            text=True, errors="replace", bufsize=1, env=env)
        time.sleep(2.0)
        rc = flash_bit()
        fh.write("### FLASH returncode=%d @ %s\n" % (rc, ts()))
        fh.flush()

        boot = False
        deadline = time.time() + 330
        while time.time() < deadline:
            line = proc.stdout.readline()
            if not line:
                if proc.poll() is not None:
                    break
                continue
            line = line.rstrip("\n")
            fh.write("%s\t%s\n" % (ts(), line))
            fh.flush()
            if "MMT_LIVE_BOOT" in line:
                boot = True
                print("   " + line, flush=True)
                break
            if "HOST_TEST_FAILED" in line:
                break
        try:
            proc.terminate()
        except Exception:
            pass
        fh.close()
        if boot:
            print("READY variant=%s log=%s" % (name, log.name), flush=True)
            return 0
        print("   attempt %d failed (no MMT_LIVE_BOOT)" % attempt, flush=True)
        time.sleep(3)
    print("FAILED to boot %s after %d attempts" % (name, a.attempts), flush=True)
    return 1


def cmd_record(a) -> int:
    import serial

    log = HERE / ("log_v16_%s.log" % a.variant)
    fh = log.open("a", encoding="utf-8", newline="\n")
    fh.write("### RECORD_START %s\n" % ts())
    fh.flush()

    stop = threading.Event()

    def pump(port):
        while not stop.is_set():
            try:
                n = port.in_waiting
                if n:
                    data = port.read(n)
                    for raw in data.split(b"\n"):
                        txt = raw.decode("ascii", "replace").strip()
                        if txt:
                            fh.write("%s\t%s\n" % (ts(), txt))
                    fh.flush()
                else:
                    time.sleep(0.02)
            except Exception:
                break

    with serial.Serial(a.port, 115200, timeout=0.1) as port:
        port.reset_input_buffer()
        # pre-flight: the firmware must already be running
        probe = b""
        t0 = time.time()
        while time.time() - t0 < 3.0:
            probe += port.read(max(1, port.in_waiting))
        n_osd = probe.count(b"MMT_OSD")
        if n_osd < 2:
            fh.write("### RECORD_ABORT no_firmware osd=%d @ %s\n" % (n_osd, ts()))
            fh.close()
            print("ABORT: firmware not running (MMT_OSD=%d in 3 s) -> reload needed" % n_osd, flush=True)
            return 2
        print("pre-flight OK: %d MMT_OSD lines in 3 s" % n_osd, flush=True)
        t = threading.Thread(target=pump, args=(port,), daemon=True)
        t.start()
        for key, desc, secs in SCENES:
            fh.write("### SEGMENT VARIANT=%s | SCENE=%s | %s | secs=%d @ %s\n"
                     % (a.variant, key, desc, secs, ts()))
            fh.flush()
            print("   >>> %s  (%d s)" % (key, secs), flush=True)
            time.sleep(secs)
            fh.write("### SCENE_END %s %s @ %s\n" % (a.variant, key, ts()))
            fh.flush()
            print("   <<< %s done" % key, flush=True)
        stop.set()
        time.sleep(0.3)
    fh.write("### RECORD_END %s\n" % ts())
    fh.close()
    print("scenes written to", log.name, flush=True)
    return 0


def cmd_one(a) -> int:
    """Record exactly one scene."""
    import serial

    log = HERE / ("log_v16_%s.log" % a.variant)
    desc = dict((k, d) for k, d, _ in SCENES).get(a.scene, a.scene)
    fh = log.open("a", encoding="utf-8", newline="\n")
    stop = threading.Event()

    def pump(port):
        while not stop.is_set():
            try:
                n = port.in_waiting
                if n:
                    data = port.read(n)
                    for raw in data.split(b"\n"):
                        txt = raw.decode("ascii", "replace").strip()
                        if txt:
                            fh.write("%s\\t%s\\n" % (ts(), txt))
                    fh.flush()
                else:
                    time.sleep(0.02)
            except Exception:
                break

    with serial.Serial(a.port, 115200, timeout=0.1) as port:
        port.reset_input_buffer()
        probe = b""
        t0 = time.time()
        while time.time() - t0 < 2.5:
            probe += port.read(max(1, port.in_waiting))
        if probe.count(b"MMT_OSD") < 1:
            fh.write("### ONE_ABORT %s no_firmware @ %s\\n" % (a.scene, ts()))
            fh.close()
            print("ABORT: firmware not running -> reload needed", flush=True)
            return 2
        t = threading.Thread(target=pump, args=(port,), daemon=True)
        t.start()
        fh.write("### SEGMENT VARIANT=%s | SCENE=%s | %s | secs=%d @ %s\\n"
                 % (a.variant, a.scene, desc, a.secs, ts()))
        fh.flush()
        print("   >>> %s (%d s)  %s" % (a.scene, a.secs, desc), flush=True)
        time.sleep(a.secs)
        fh.write("### SCENE_END %s %s @ %s\\n" % (a.variant, a.scene, ts()))
        fh.flush()
        stop.set()
        time.sleep(0.3)
    fh.close()
    print("   <<< %s done" % a.scene, flush=True)
    return 0


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("mode", choices=["load", "record", "one"])
    ap.add_argument("--image", default=None)
    ap.add_argument("--variant", default=None)
    ap.add_argument("--port", default="COM15")
    ap.add_argument("--attempts", type=int, default=5)
    ap.add_argument("--scene", default="S1_nobody")
    ap.add_argument("--secs", type=float, default=35)
    a = ap.parse_args()
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8")
    if a.mode == "load":
        if not a.image:
            ap.error("--image required")
        return cmd_load(a)
    if not a.variant:
        ap.error("--variant required")
    if a.mode == "one":
        return cmd_one(a)
    return cmd_record(a)


if __name__ == "__main__":
    sys.exit(main())
