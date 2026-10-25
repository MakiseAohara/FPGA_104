#!/usr/bin/env python3
"""capture_v16.py - automated variant capture for the v16 preprocessing A/B.

For every variant it:
  1. starts the UART loader (waits for MMT_LOADER_READY),
  2. flashes the bitstream (resets the board and pushes the firmware),
  3. waits for MMT_LIVE_BOOT,
  4. records 3 scenes x 35 s with a 12 s countdown before each one,
writing one continuously timestamped log per variant with SEGMENT markers.

Variant order is randomised with a fixed seed; the full plan is printed first.

Usage:
  python capture_v16.py --plan-only
  python capture_v16.py --port COM15 --variants tinyml_pdti8_v16_base_dump.bin
"""
from __future__ import annotations

import argparse
import datetime as dt
import os
import random
import subprocess
import sys
import threading
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
PY = sys.executable
LOADER_PY = r"D:\\Efinity\\2026.1\\python311\\bin\\python.exe"  # has pyserial
FLASH = Path(r"C:\Users\Makise Aohara\Documents\Codex\2026-10-15"
             r"\https-github-com-makiseaohara-fpga-104\outputs"
             r"\fpga_onboard_verified_20261020\tools\flash_vendor.ps1")
BIT = HERE / "v7_MERGE11.bit"
BIT_SHA = "ECE19288C8C34C64B29554310287ABC810FC2FB6388350D998DA5C47DAA14C15"
LOADER = HERE / "tools" / "load_and_run.py"

SCENES = [
    ("S1_nobody", "nobody in frame", 35),
    ("S2_person_1m", "person ~1 m, facing camera", 35),
    ("S3_person_0p5m", "person ~0.5 m, facing camera", 35),
]
COUNTDOWN = 12
MAX_ATTEMPTS = 4
SEED = 20261104


def ts() -> str:
    return dt.datetime.now().isoformat(timespec="milliseconds")


def bell() -> None:
    print("\a", end="", flush=True)


def banner(lines, ch="=") -> None:
    w = max(len(x) for x in lines) + 8
    print(ch * w)
    for x in lines:
        print("  " + x)
    print(ch * w, flush=True)


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
    if r.returncode != 0:
        print((r.stdout or "")[-500:], flush=True)
        print((r.stderr or "")[-300:], flush=True)
    return r.returncode


class Loader:
    """Run load_and_run.py and re-emit its stdout with host timestamps."""

    def __init__(self, port: str, image: Path, log: Path, run_timeout: float):
        self.log = log
        self.lines = []
        self.boot = False
        self.fh = log.open("a", encoding="utf-8", newline="\n")
        self.fh.write("### HOST_T0 %s\n" % ts())
        env = os.environ.copy()
        env["PYTHONHOME"] = r"D:/Efinity/2026.1/python311"
        self.proc = subprocess.Popen(
            [LOADER_PY, str(LOADER), "--port", port, "--image", str(image),
             "--out", str(HERE / "_runs" / image.stem),
             "--boot-timeout", "45", "--run-timeout", str(run_timeout)],
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
            text=True, errors="replace", bufsize=1, env=env)
        self.t = threading.Thread(target=self._pump, daemon=True)
        self.t.start()

    def _pump(self):
        for line in self.proc.stdout:
            line = line.rstrip("\n")
            self.fh.write("%s\t%s\n" % (ts(), line))
            self.lines.append(line)
            if "MMT_LIVE_BOOT" in line:
                self.boot = True
            if line.strip():
                print("   | " + line[:110], flush=True)
        self.fh.flush()

    def marker(self, text: str):
        self.fh.write("### SEGMENT %s @ %s\n" % (text, ts()))
        self.fh.flush()

    def note(self, text: str):
        self.fh.write("### %s @ %s\n" % (text, ts()))
        self.fh.flush()

    def wait_boot(self, timeout: float) -> bool:
        end = time.time() + timeout
        while time.time() < end:
            if self.boot:
                return True
            if self.proc.poll() is not None:
                return self.boot
            time.sleep(0.1)
        return self.boot

    def close(self):
        try:
            self.proc.terminate()
        except Exception:
            pass
        self.t.join(timeout=3)
        self.fh.close()


def run_variant(port, image: Path, variant: str, attempt: int = 1) -> bool:
    log = HERE / ("log_v16_%s.log" % variant)
    if attempt > 1:
        log = HERE / ("log_v16_%s_retry%d.log" % (variant, attempt))
    banner(["VARIANT " + variant, "firmware " + image.name,
            "attempt %d" % attempt, "log " + log.name])
    ld = Loader(port, image, log, run_timeout=3 * (COUNTDOWN + 35) + 40)
    time.sleep(2.0)
    rc = flash_bit()
    ld.note("FLASH returncode=%d" % rc)
    if rc != 0:
        print("   flash failed", flush=True)
        ld.close()
        return False
    if not ld.wait_boot(50):
        print("   no MMT_LIVE_BOOT", flush=True)
        ld.close()
        return False

    for key, desc, secs in SCENES:
        banner(["NEXT: " + key, desc,
                "countdown %d s, then record %d s" % (COUNTDOWN, secs)])
        bell()
        for i in range(COUNTDOWN, 0, -1):
            print("\r   countdown %2d ..." % i, end="", flush=True)
            time.sleep(1.0)
        print("\r" + " " * 26 + "\r", end="", flush=True)
        ld.marker("VARIANT=%s | SCENE=%s | %s | secs=%d" % (variant, key, desc, secs))
        bell()
        print("   >>> RECORDING %ds" % secs, flush=True)
        time.sleep(secs)
        ld.note("SCENE_END %s %s" % (variant, key))
        bell()
        print("   <<< done", flush=True)

    ld.close()
    return True


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", default="COM15")
    ap.add_argument("--dir", type=Path, default=HERE)
    ap.add_argument("--variants", nargs="*", default=None)
    ap.add_argument("--plan-only", action="store_true")
    ap.add_argument("--no-shuffle", action="store_true")
    a = ap.parse_args()

    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8")

    found = sorted(p.name for p in a.dir.glob("tinyml_pdti8_v16_*_dump.bin"))
    names = list(a.variants) if a.variants else found

    order = list(names)
    if not a.no_shuffle:
        random.Random(SEED).shuffle(order)

    banner(["v16 capture plan: %d variant(s), randomised" % len(order),
            "seed = %d" % SEED,
            "each variant: flash bitstream + load firmware, then 3 scenes x 35 s",
            "scene order: nobody -> 1 m -> 0.5 m, 12 s countdown before each"] +
           ["%d. %s" % (i + 1, v) for i, v in enumerate(order)])

    if a.plan_only:
        print("\n(plan only, nothing executed)")
        return 0

    ok, failed = [], []
    for idx, v in enumerate(order, 1):
        img = a.dir / v
        if not img.is_file():
            print("[%d/%d] MISSING %s" % (idx, len(order), img.name))
            failed.append(v)
            continue
        banner(["[%d/%d] %s" % (idx, len(order), v)])
        good = False
        for attempt in range(1, MAX_ATTEMPTS + 1):
            good = run_variant(a.port, img, Path(v).stem, attempt=attempt)
            if good:
                break
            print("   retry %d/%d ..." % (attempt, MAX_ATTEMPTS - 1), flush=True)
        (ok if good else failed).append(v)

    banner(["capture finished", "ok: %s" % ok, "failed: %s" % failed])
    return 0


if __name__ == "__main__":
    sys.exit(main())
