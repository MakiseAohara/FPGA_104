"""v19 gate capture: immutable image, continuous UART, bounded acquisition retries.

Adapted from the project's evidence/v26_gate/capture_v26.py and v19/free_capture.py.
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

sys.dont_write_bytecode = True
TZ = dt.timezone(dt.timedelta(hours=8))
CRC = "B7CCB8D0"
SHA = "BEF15238095C194D4A734BD9F40ED22A0BA6361F325CEB6395AAF51AF9E9828C"
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
        self.fh = (out / "log_v26_gate.log").open("a" if resume else "x", encoding="utf-8", newline="\n")
        self.uart_fh = (out / "uart_bytes.bin").open("ab" if resume else "xb")
        self.last_rx = time.monotonic()
        self.last_gap = self.last_rx
        self.lines = self.gaps = self.reconnects = self.dec_count = 0
        self.last_dec = None
        self.t0 = None
        self.phase = "LOADING"
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
            if text.startswith(("MMT_DEC ", "### PROMPT", "### CAPTURE")):
                publish_state(self)


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
                self.cap.uart_fh.write(data)
                self.cap.uart_fh.flush()
                self.cap.rx()
                self.buf += data
        if b"\n" in self.buf:
            raw, self.buf = self.buf.split(b"\n", 1)
            # Firmware prints LF followed by CR; keep that CR out of the next
            # line's framing while retaining the exact printable UART payload.
            text = raw.strip(b"\r").decode("ascii", errors="replace")
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



PROTOCOL = [
    (0,"EMPTY_INITIAL","初始空场两分钟。请同学按实际动作记录人工标注。"),
    (120,"ENTER_FIRST","第一段，请进入画面，在一到两米处站稳，保持上半身可见，停留两分钟。"),
    (240,"LEAVE_FIRST","请离开画面，接下来空场三十秒。"),
    (270,"CHAIR_START","椅子片段三十秒，保持人退出画面，用绳子拉椅子，或者推入椅子后立即离开。"),
    (300,"ENTER_SECOND","椅子片段结束，请第二次进入画面，停留两分钟。"),
    (330,"HEAD_DOWN","请低头十秒。"),
    (340,"HEAD_UP","低头片段结束，恢复站立。"),
    (360,"SIDE_BODY","请侧身十秒。"),
    (370,"FACE_FRONT","侧身片段结束，恢复站立。"),
    (420,"LEAVE_SECOND","请离开画面，保持空场一分钟，等待低功耗。"),
    (480,"ENTER_WAKE","请再进入画面，观察唤醒，停留一分钟。"),
    (540,"LEAVE_WAKE","请离开画面，最后空场一分钟。"),
    (600,"END","采集结束。请同学保存人工标注时间表。"),
]

def publish_state(cap):
    state = dict(t0=cap.t0,phase=cap.phase,device_ms=cap.last_dec,wall=wall())
    try:
        pending = cap.out / "live_state.tmp"
        pending.write_text(json.dumps(state,ensure_ascii=False),encoding="utf-8",newline="\n")
        os.replace(pending,cap.out / "live_state.json")
    except OSError:
        pass  # Annotation display issues must not interrupt UART reception.

def say(text):
    command = "Add-Type -AssemblyName System.Speech; $s=New-Object System.Speech.Synthesis.SpeechSynthesizer; $s.Speak('"+text.replace("'","''")+"')"
    try:
        subprocess.Popen([powershell(),"-NoProfile","-Command",command],env=powershell_env(),
                         stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,creationflags=subprocess.CREATE_NO_WINDOW)
    except OSError:
        pass

def run_protocol(cap,args,metadata):
    metadata["observation_started_wall"] = wall()
    cap.t0 = metadata["observation_started_wall"]
    start = time.monotonic()
    print("PROTOCOL_T0",cap.t0,"duration=600",flush=True)
    cap.log("### PROTOCOL_START t0=%s duration=600 manual_annotation_required=1" % cap.t0)
    publish_state(cap)
    with (args.out / "script_prompts.csv").open("w",encoding="utf-8",newline="") as stream:
        writer = csv.DictWriter(stream,fieldnames=["scheduled_s","wall","event","device_ms_latest","note"])
        writer.writeheader()
        for offset,event,note in PROTOCOL:
            if cap.stop.wait(max(0,start+offset-time.monotonic())):
                raise RuntimeError(cap.fatal or "capture interrupted")
            cap.phase = event
            row = dict(scheduled_s=offset,wall=wall(),event=event,device_ms_latest=cap.last_dec,note=note)
            writer.writerow(row);stream.flush()
            cap.log("### PROMPT event=%s scheduled_s=%d latest_device_ms=%s manual_label=0" % (event,offset,cap.last_dec))
            print("PROMPT",offset,event,row["wall"],flush=True)
            say(note)
    metadata["observation_ended_wall"] = wall()
    metadata["observation_completed"] = True
    metadata["schedule_completed"] = True
    cap.log("### PROTOCOL_END manual_annotations_separate=1")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--image", type=Path, required=True)
    ap.add_argument("--bit", type=Path, required=True)
    ap.add_argument("--flash", type=Path, required=True)
    ap.add_argument("--efinity", type=Path, default=Path(r"D:\Efinity\2026.1"))
    ap.add_argument("--out", type=Path, required=True)
    ap.add_argument("--port", default="COM15")
    ap.add_argument("--resume", action="store_true", help="Append after explicit authorization for further attempts")
    ap.add_argument("--observe-seconds", type=float, default=600, help="Free movement observation; no prompts or action markers")
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
                "operator_power_cycle": "not requested or performed in v26; user reported reconnecting serial",
                "mode": "manual_protocol_v26",
                "observation_seconds": args.observe_seconds,
                "requested_protocol": "empty120 + person120 + empty30 + chair30 + person120(head/side10 each) + empty60 + wake_person60 + final_empty60",
                "physical_actions": "operator annotations required; script prompts are not ground truth",
                "flash_authorization": "user explicitly authorized v26 candidate CRC32 B7CCB8D0; do not wait for IR",
                "action_prompts": True, "enter_leave_markers": False,
                "manual_annotation_file": "manual_events_raw.csv",
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
        run_protocol(cap,args,metadata)
        if cap.dec_count == 0:
            raise RuntimeError("No MMT_DEC records during capture")
    except Exception as exc:
        error = repr(exc)
        cap.log("### ACQUISITION_ERROR " + error)
        print(traceback.format_exc(), flush=True)
        (args.out / "FAILED.md").write_text(
            "# v26_gate acquisition interruption\n\n"
            "- Wall time (Asia/Shanghai): " + wall() + "\n"
            "- Error: `" + error + "`\n"
            "- Acquisition attempts recorded: %d; this authorization allowed %d additional attempts.\n" % (len(attempts), args.max_attempts) +
            "- No firmware compilation, exposure/AE changes, or reset after upload.\n"
            "- Capture disconnections are reconnected without reflashing.\n"
            "- See log_v26_gate.log, attempts.json, and flash_attempt_*.log.\n"
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
        cap.uart_fh.close()
        (args.out / "run_metadata.json").write_text(json.dumps(metadata, ensure_ascii=False, indent=2)+"\n", encoding="utf-8")
        (args.out / "attempts.json").write_text(json.dumps(attempts, ensure_ascii=False, indent=2)+"\n", encoding="utf-8")
    return int(error is not None)


if __name__ == "__main__":
    raise SystemExit(main())
