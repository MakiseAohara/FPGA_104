"""v19 gate capture: immutable image, continuous UART, bounded acquisition retries.

Adapted from the project's evidence/v22_gate/capture_v22.py and v19/free_capture.py.
No firmware compilation, camera writes, SPI writes, or reset after firmware upload.
"""
import argparse
import binascii
import csv
import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import re
import struct
import subprocess
import sys
import threading
import time
import traceback

TZ = dt.timezone(dt.timedelta(hours=8))
CRC = "9410DBEF"
SHA = "8C0AE09D06851257D5412EC834C5BF143D91BFE2F30D111AC298BC571F0D2AD3"
BIT_SHA = "E399F99067E6544262315607B27FC3DD2394F37FD245F909DEE1EBA8A8B41FE8"


def wall():
    return dt.datetime.now(TZ).isoformat(timespec="milliseconds")


def powershell_env():
    env = os.environ.copy()
    for key in list(env):
        if key.upper() in ("PYTHONHOME", "PSMODULEPATH"):
            env.pop(key)
    # Python inherits PS7's module directories; PS5 otherwise shadows its own
    # Utility module and cannot autoload Get-FileHash. Verify before UART/JTAG.
    env["PSModulePath"] = (r"C:\Windows\System32\WindowsPowerShell\v1.0\Modules;"
                           r"C:\Program Files\WindowsPowerShell\Modules")
    return env


def powershell():
    return r"C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe"


class ActiveProgrammingError(RuntimeError):
    pass


class Capture:
    def __init__(self, out, resume=False):
        self.out = out
        self.lock = threading.RLock()
        self.fh = (out / "log_v22_gate.log").open("a" if resume else "x", encoding="utf-8", newline="\n")
        self.last_rx = time.monotonic()
        self.last_gap = self.last_rx
        self.lines = self.gaps = self.reconnects = self.dec_count = 0
        self.last_dec = None
        self.boots = []
        self.cams = []
        self.stop = threading.Event()
        self.fatal = None

    def log(self, text, serial_line=False):
        with self.lock:
            self.fh.write(wall() + "\t" + text + "\n")
            self.fh.flush()
            if serial_line:
                self.lines += 1
                match = re.search(r"MMT_DEC t=(\d+)", text)
                if match:
                    self.last_dec = int(match[1])
                    self.dec_count += 1
                if text.startswith("MMT_LIVE_BOOT"):
                    self.boots.append(text)
                if text.startswith("MMT_CAM"):
                    self.cams.append(text)

    def rx(self):
        with self.lock:
            self.last_rx = self.last_gap = time.monotonic()

    def gap_check(self):
        now = time.monotonic()
        with self.lock:
            if now - self.last_rx > 5 and now - self.last_gap >= 5:
                self.gaps += 1
                self.log("### GAP idle_s=%.3f device_ms=%s" % (now-self.last_rx, self.last_dec))
                self.last_gap = now


class Reader:
    def __init__(self, port, capture):
        self.port, self.cap, self.buf = port, capture, b""

    def next_line(self):
        if b"\n" not in self.buf:
            data = self.port.read(max(1, self.port.in_waiting))
            if data:
                self.cap.rx()
                self.buf += data
        if b"\n" in self.buf:
            raw, self.buf = self.buf.split(b"\n", 1)
            text = raw.rstrip(b"\r").decode("ascii", errors="replace")
            self.cap.log(text, serial_line=True)
            return text
        self.cap.gap_check()
        return None

    def until(self, token, timeout):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            text = self.next_line()
            if text:
                if text.startswith(("MMT_DDR_FAIL", "MMT_LOAD_FAIL", "MMT_AI_FAIL")):
                    raise RuntimeError(text)
                if token in text:
                    print(text, flush=True)
                    return text
        raise TimeoutError("Waiting for " + token)


def port_open(serial, name):
    # Opening/reopening UART must not deliberately toggle the reset lines.
    port = serial.Serial(port=None, baudrate=115200, timeout=0.05, write_timeout=5)
    port.dtr = False
    port.rts = False
    port.port = name
    port.open()
    return port


def flash_and_upload(args, cap, serial, data, attempt):
    port = port_open(serial, args.port)
    reader = Reader(port, cap)
    flash = None
    try:
        # Log any buffered old execution BEFORE the explicitly marked new flash.
        deadline = time.monotonic() + 0.6
        while time.monotonic() < deadline:
            reader.next_line()
        cap.log("### FLASH_START attempt=%d" % attempt)
        env = powershell_env()
        cap.boots.clear()
        cap.cams.clear()
        cap.dec_count = 0
        cap.last_dec = None
        flash_log = args.out / ("flash_attempt_%d.log" % attempt)
        command = [powershell(), "-NoProfile", "-ExecutionPolicy", "Bypass", "-File",
                   str(args.flash), "-Bit", str(args.bit), "-Sha256", BIT_SHA,
                   "-EfinityHome", str(args.efinity), "-ExpectedDriverVersion", "2.12.36.20",
                   "-UsbUrl", "hiftdi://0x0403:0x6011/1", "-LogRoot", str(args.out / "flash_logs")]
        with flash_log.open("wb") as output:
            flash = subprocess.Popen(command, stdout=output, stderr=subprocess.STDOUT, env=env,
                                     creationflags=subprocess.CREATE_NO_WINDOW)
            ready = False
            deadline = time.monotonic() + 100
            while time.monotonic() < deadline:
                line = reader.next_line()
                if line and "MMT_LOADER_READY" in line:
                    ready = True
                    print(line, flush=True)
                if flash.poll() is not None:
                    if flash.returncode:
                        raise RuntimeError("JTAG script exit=%d; see %s" % (flash.returncode, flash_log.name))
                    if ready:
                        break
                if line and line.startswith("MMT_DDR_FAIL"):
                    raise RuntimeError(line)
            else:
                raise TimeoutError("JTAG/loader not ready within 100 s")
        cap.log("### FLASH_END attempt=%d exit=%d" % (attempt, flash.returncode))
        port.write(b"MMTL" + struct.pack("<II", len(data), binascii.crc32(data) & 0xffffffff))
        reader.until("MMT_LOAD_ACCEPT", 8)
        progress = -1
        for offset in range(0, len(data), 64):
            block = data[offset:offset+64]
            if port.write(block) != len(block):
                raise IOError("short write offset=%d" % offset)
            for retry in range(3):
                acknowledged = False
                deadline = time.monotonic() + 6
                while time.monotonic() < deadline:
                    c = port.read(1)
                    if c:
                        cap.rx()
                    if c == b"\x06":
                        acknowledged = True
                        break
                if acknowledged:
                    break
                cap.log("### BLOCK_ACK_TIMEOUT block=%d try=%d" % (offset//64, retry+1))
                if retry < 2:
                    port.write(block)
            if not acknowledged:
                raise IOError("Block %d no acknowledgement after 3 tries" % (offset//64))
            pct = (offset+len(block))*10//len(data)
            if pct != progress:
                print("IMAGE_UPLOAD %d%%" % (pct*10), flush=True)
                progress = pct
        cap.log("### IMAGE_UPLOAD_END bytes=%d crc32=%s" % (len(data), CRC))
        reader.until("MMT_LOAD_PASS DDR_CRC", 40)
        reader.until("MMT_LIVE_BOOT", 30)
        # This exact reader, including every unread byte, continues into capture.
        return reader
    except BaseException:
        if flash is not None and flash.poll() is None:
            # Do not interrupt an active programming transaction. Bound its wait.
            try:
                flash.wait(timeout=30)
            except subprocess.TimeoutExpired:
                cap.log("### JTAG_PROCESS_STILL_RUNNING pid=%d" % flash.pid)
                port.close()
                raise ActiveProgrammingError("JTAG process still running; further retries prohibited")
        if reader.buf:
            cap.log("### PRE_CAPTURE_PENDING_HEX " + reader.buf.hex())
        port.close()
        raise


def pump(reader, args, serial):
    cap = reader.cap
    while not cap.stop.is_set():
        try:
            reader.next_line()
        except Exception as exc:
            cap.log("### RECONNECT_TRY error=" + repr(exc))
            if reader.buf:
                cap.log("### PARTIAL_LINE_HEX " + reader.buf.hex())
                reader.buf = b""
            try:
                reader.port.close()
            except Exception:
                pass
            deadline = time.monotonic() + 30
            while not cap.stop.is_set() and time.monotonic() < deadline:
                try:
                    reader.port = port_open(serial, args.port)
                    cap.reconnects += 1
                    cap.log("### RECONNECTED count=%d no_reflash=1" % cap.reconnects)
                    break
                except Exception:
                    cap.gap_check()
                    cap.stop.wait(0.5)
            else:
                cap.fatal = "UART unavailable for 30 seconds; no reflash during capture"
                cap.stop.set()


def speak(text, cap):
    # Local prompts only; independent of UART and never ask for confirmation.
    escaped = text.replace("'", "''")
    command = "Add-Type -AssemblyName System.Speech; $s=New-Object System.Speech.Synthesis.SpeechSynthesizer; $s.Speak('"+escaped+"')"
    try:
        subprocess.Popen([powershell(), "-NoProfile", "-Command", command], env=powershell_env(),
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                         creationflags=subprocess.CREATE_NO_WINDOW)
    except Exception as exc:
        cap.log("### AUDIO_PROMPT_UNAVAILABLE " + repr(exc))


def schedule(cap, args):
    with (args.out / "script_events_raw.csv").open("w", encoding="utf-8", newline="") as fh:
        writer = csv.DictWriter(fh, fieldnames=["event", "wall", "device_ms", "note"])
        writer.writeheader()

        def event(name, note, speech):
            stamp = wall()
            row = dict(event=name, wall=stamp, device_ms=cap.last_dec, note=note)
            writer.writerow(row)
            fh.flush()
            cap.log("### EVT %s wall=%s latest_device_ms=%s note=%s" % (name, stamp, cap.last_dec, note))
            print("PROMPT %s wall=%s device_ms=%s %s" % (name, stamp, cap.last_dec, note), flush=True)
            speak(speech, cap)

        def pause(seconds):
            if cap.stop.wait(seconds):
                raise RuntimeError(cap.fatal or "capture interrupted")

        event("IDLE0", "empty 30s", "请保持空场三十秒，开始低功耗等待。")
        pause(30)
        for k in range(1, 7):
            event("ENTER%d" % k, "walk in and stand 20s", "第%d轮，请走进画面并站稳二十秒。" % k)
            pause(20)
            event("LEAVE%d" % k, "walk out then empty 30s", "第%d轮，请走出画面，保持空场三十秒。" % k)
            pause(30)
        event("IDLE_END", "empty 60s", "六轮提示结束，请继续保持空场六十秒。")
        pause(60)
        event("END", "schedule complete", "本次采集结束。")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--image", type=Path, required=True)
    ap.add_argument("--bit", type=Path, required=True)
    ap.add_argument("--flash", type=Path, required=True)
    ap.add_argument("--efinity", type=Path, default=Path(r"D:\Efinity\2026.1"))
    ap.add_argument("--out", type=Path, required=True)
    ap.add_argument("--port", default="COM15")
    ap.add_argument("--resume", action="store_true", help="Append after explicit authorization for further attempts")
    ap.add_argument("--boot-only", type=float, default=0, help="Observe this many seconds, without human action prompts")
    ap.add_argument("--max-attempts", type=int, choices=[1, 2, 3], default=3)
    args = ap.parse_args()
    args.out.mkdir(parents=True, exist_ok=True)
    cap = Capture(args.out, resume=args.resume)
    metadata = {"started_wall": wall(), "firmware_file": args.image.name,
                "firmware_crc32": None, "firmware_sha256": None, "firmware_bytes": None,
                "bitstream_file": args.bit.name, "bitstream_sha256": None,
                "port": args.port, "baudrate": 115200, "timezone": "Asia/Shanghai",
                "max_acquisition_attempts_this_run": args.max_attempts, "firmware_modified": False,
                "exposure_modified": False, "camera_commands_sent": False,
                "reset_after_firmware_upload": False,
                "operator_power_cycle": "reported complete before task by user",
                "mode": "boot_only" if args.boot_only else "six_round_gate",
                "schedule_seconds": 0 if args.boot_only else 390,
                "schedule": "paused by user; no ENTER/LEAVE prompts" if args.boot_only else "empty30 + 6*(ENTER20 + LEAVE_empty30) + empty60",
                "physical_actions": "none requested" if args.boot_only else "prompted; no independent confirmation",
                "schedule_completed": False}
    attempts = json.loads((args.out / "attempts.json").read_text(encoding="utf-8")) if args.resume and (args.out / "attempts.json").exists() else []
    prior_count = len(attempts)
    metadata["prior_attempts"] = prior_count
    error = None
    reader = thread = None
    try:
        cap.log("### CAPTURE_START timezone=Asia/Shanghai continuous_log=1")
        data = args.image.read_bytes()
        crc = "%08X" % (binascii.crc32(data) & 0xffffffff)
        sha = hashlib.sha256(data).hexdigest().upper()
        metadata.update(firmware_crc32=crc, firmware_sha256=sha, firmware_bytes=len(data))
        cap.log("### FIRMWARE_CHECK bytes=%d CRC32=%s SHA256=%s" % (len(data), crc, sha))
        if crc != CRC or sha != SHA or len(data) != 477722:
            raise ValueError("Firmware identity mismatch; stopped before flashing")
        bit_sha = hashlib.sha256(args.bit.read_bytes()).hexdigest().upper()
        metadata["bitstream_sha256"] = bit_sha
        if bit_sha != BIT_SHA:
            raise ValueError("Bitstream SHA256 mismatch; stopped before flashing")
        check = subprocess.run([powershell(), "-NoProfile", "-Command",
                                "$ErrorActionPreference='Stop'; Get-Command Get-FileHash,Get-PnpDevice,Get-CimInstance | Select-Object Name,ModuleName | ConvertTo-Json"],
                               env=powershell_env(), capture_output=True, timeout=20)
        (args.out / "powershell_preflight.log").write_bytes(check.stdout + check.stderr)
        if check.returncode:
            raise RuntimeError("PowerShell module preflight failed before any hardware operation")
        cap.log("### HOST_PREFLIGHT PS5_native_modules=1 Get-FileHash=available")
        vendor = args.efinity / "python311" / "Lib" / "site-packages"
        sys.path.append(str(vendor))
        import serial
        for k in range(prior_count + 1, prior_count + args.max_attempts + 1):
            record = {"attempt": k, "started_wall": wall()}
            attempts.append(record)
            cap.log("### ATTEMPT_START attempt=%d" % k)
            try:
                reader = flash_and_upload(args, cap, serial, data, k)
                record.update(ended_wall=wall(), upload_completed=True)
                break
            except Exception as exc:
                record.update(ended_wall=wall(), upload_completed=False, error=repr(exc))
                cap.log("### ATTEMPT_ERROR attempt=%d error=%r" % (k, exc))
                print("ATTEMPT_ERROR", k, repr(exc), flush=True)
                if isinstance(exc, ActiveProgrammingError) or k == prior_count + args.max_attempts:
                    raise RuntimeError("Authorized acquisition attempts stopped: " + repr(exc)) from exc
                time.sleep(2)
        metadata["active_boot"] = cap.boots[-1] if cap.boots else None
        thread = threading.Thread(target=pump, args=(reader, args, serial), daemon=True)
        thread.start()
        if args.boot_only:
            metadata["observation_started_wall"] = wall()
            cap.log("### BOOT_ONLY_START seconds=%s human_schedule=paused" % args.boot_only)
            if cap.stop.wait(args.boot_only):
                raise RuntimeError(cap.fatal or "capture interrupted")
            metadata["observation_ended_wall"] = wall()
            cap.log("### BOOT_ONLY_END no_ENTER_LEAVE_prompts=1")
        else:
            metadata["schedule_started_wall"] = wall()
            schedule(cap, args)
            metadata["schedule_completed"] = True
            metadata["schedule_ended_wall"] = wall()
        if cap.dec_count == 0:
            raise RuntimeError("No MMT_DEC records during capture")
        if not cap.cams:
            raise RuntimeError("No MMT_CAM boot lines captured")
    except Exception as exc:
        error = repr(exc)
        cap.log("### ACQUISITION_ERROR " + error)
        print(traceback.format_exc(), flush=True)
        (args.out / "FAILED.md").write_text(
            "# v22_gate acquisition interruption\n\n"
            "- Wall time (Asia/Shanghai): " + wall() + "\n"
            "- Error: `" + error + "`\n"
            "- Acquisition attempts recorded: %d; this authorization allowed %d additional attempts.\n" % (len(attempts), args.max_attempts) +
            "- No firmware compilation, exposure/AE changes, or reset after upload.\n"
            "- Capture disconnections are reconnected without reflashing.\n"
            "- See log_v22_gate.log, attempts.json, and flash_attempt_*.log.\n"
            "- No pass/fail assessment of detector behavior was made.\n", encoding="utf-8")
    finally:
        cap.stop.set()
        if thread:
            thread.join(timeout=3)
        if reader:
            if reader.buf:
                cap.log("### FINAL_PARTIAL_LINE_HEX " + reader.buf.hex())
            reader.port.close()
        metadata.update(ended_wall=wall(), gaps=cap.gaps, reconnects=cap.reconnects,
                        serial_lines=cap.lines, dec_records=cap.dec_count, acquisition_error=error)
        cap.log("### CAPTURE_END lines=%d gaps=%d reconnects=%d error=%s" %
                (cap.lines, cap.gaps, cap.reconnects, error))
        cap.fh.close()
        (args.out / "run_metadata.json").write_text(json.dumps(metadata, ensure_ascii=False, indent=2)+"\n", encoding="utf-8")
        (args.out / "attempts.json").write_text(json.dumps(attempts, ensure_ascii=False, indent=2)+"\n", encoding="utf-8")
    return int(error is not None)


if __name__ == "__main__":
    raise SystemExit(main())
