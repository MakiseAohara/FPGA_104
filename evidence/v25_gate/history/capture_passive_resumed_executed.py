"""Passive UART capture only: no programming, resets, writes, or action prompts."""
import argparse
import datetime as dt
import json
from pathlib import Path
import re
import sys
import time

sys.dont_write_bytecode = True
TZ = dt.timezone(dt.timedelta(hours=8))


def wall():
    return dt.datetime.now(TZ).isoformat(timespec="milliseconds")


def open_port(serial, name):
    port = serial.Serial(port=None, baudrate=115200, timeout=0.1)
    # Set inactive control lines before opening. Never toggle them afterwards.
    port.dtr = False
    port.rts = False
    port.port = name
    try:
        port.open()
    except Exception:
        port.close()
        raise
    return port


def capture(args, serial):
    args.out.mkdir(parents=True, exist_ok=True)
    metadata = dict(
        mode="passive_free_movement", port=args.port, baudrate=115200,
        timezone="Asia/Shanghai", planned_seconds=args.seconds,
        firmware_modified=False, flashed=False, reset_requested=False,
        camera_commands_sent=False, serial_writes=0,
        action_prompts=False, enter_leave_markers=False,
        requested_protocol="initial empty >=30s; about six free entries, each 10-20s; empty >=15s between; final empty >=60s",
        physical_actions="user-arranged; no independent entry/exit annotations",
        lighting="user-arranged indoor lighting; not independently measured",
        firmware_identity="no flash/readback in this run; candidate is immutable v19 dump",
        started_wall=wall(), connected_wall=None, ended_wall=None,
        serial_lines=0, bytes_received=0, gaps=0, reconnects=0,
        initial_open_attempts=0, last_device_ms=None,
        live_boot_lines=[], camera_lines=[], completed=False, error=None,
    )
    if args.resume:
        previous = json.loads((args.out / "run_metadata.json").read_text(encoding="utf-8"))
        metadata.update(previous)
        metadata["reader_restarts"] = metadata.get("reader_restarts", 0) + 1
        metadata["reader_restarted_wall"] = wall()
        metadata["completed"] = False
        metadata["error"] = None
        metadata["gaps"] = sum(b"\t### GAP " in line for line in (args.out / "log_v25_gate.log").read_bytes().split(b"\n"))
    metadata.setdefault("open_cycles", metadata["initial_open_attempts"])
    metadata.setdefault("first_received_wall", None)
    port = None
    pending = b""
    last_rx = last_gap = time.monotonic()
    failure_rounds = 0
    deadline = None
    failure_deadline = time.monotonic() + 30
    opened_at = None
    log_path = args.out / "log_v25_gate.log"
    raw_path = args.out / "uart_bytes.bin"
    with log_path.open("ab" if args.resume else "xb") as log, raw_path.open("ab" if args.resume else "xb") as raw:
        def record(body):
            if isinstance(body, str):
                body = body.encode("utf-8")
            log.write(wall().encode("ascii") + b"\t" + body + b"\n")
            log.flush()

        def save():
            (args.out / "run_metadata.json").write_text(
                json.dumps(metadata, ensure_ascii=False, indent=2) + "\n",
                encoding="utf-8", newline="\n")

        record("### %s passive=1 no_flash=1 no_reset=1 serial_writes=0 prompts=0" % (
            "HOST_READER_RESTART" if args.resume else "CAPTURE_START"))
        save()
        try:
            while deadline is None or time.monotonic() < deadline:
                now = time.monotonic()
                if now - last_rx > 5 and now - last_gap >= 5:
                    metadata["gaps"] += 1
                    record("### GAP idle_s=%.3f device_ms=%s" % (now-last_rx, metadata["last_device_ms"]))
                    last_gap = now
                if port is not None and metadata["bytes_received"] == 0 and now - opened_at >= 30:
                    record("### NO_DATA_REOPEN cycle=%d no_reset=1" % metadata["open_cycles"])
                    port.close()
                    port = None
                    if metadata["open_cycles"] >= 3:
                        raise RuntimeError("No UART bytes after three passive open cycles; no flash or board reset attempted")
                    failure_deadline = now + 30
                if port is None:
                    if now >= failure_deadline:
                        failure_rounds += 1
                        record("### OPEN_RETRY_ROUND_EXHAUSTED round=%d" % failure_rounds)
                        if failure_rounds >= 3:
                            raise RuntimeError("UART unavailable for three 30-second retry rounds")
                        failure_deadline = now + 30
                    try:
                        if metadata["connected_wall"] is None:
                            metadata["initial_open_attempts"] += 1
                        port = open_port(serial, args.port)
                    except Exception as exc:
                        if not metadata.get("last_open_error") == repr(exc):
                            record("### OPEN_ERROR " + repr(exc))
                            metadata["last_open_error"] = repr(exc)
                        time.sleep(0.5)
                        continue
                    failure_rounds = 0
                    opened_at = time.monotonic()
                    metadata["open_cycles"] += 1
                    if deadline is None:
                        metadata["connected_wall"] = metadata["connected_wall"] or wall()
                        deadline = time.monotonic() + args.seconds
                        record("### CONNECTED no_flash=1 no_reset=1")
                        print("CAPTURE_CONNECTED", wall(), flush=True)
                    else:
                        metadata["reconnects"] += 1
                        record("### RECONNECTED count=%d no_reflash=1 no_reset=1" % metadata["reconnects"])
                    save()
                try:
                    data = port.read(max(1, port.in_waiting))
                except Exception as exc:
                    record("### RECONNECT_TRY " + repr(exc))
                    if pending:
                        record("### PARTIAL_LINE_HEX " + pending.hex())
                        pending = b""
                    try:
                        port.close()
                    except Exception:
                        pass
                    port = None
                    failure_deadline = time.monotonic() + 30
                    continue
                if not data:
                    continue
                if metadata["first_received_wall"] is None:
                    metadata["first_received_wall"] = wall()
                    deadline = time.monotonic() + args.seconds
                    record("### FIRST_BYTES observation_seconds=%s" % args.seconds)
                    print("FIRST_BYTES", metadata["first_received_wall"], flush=True)
                raw.write(data)
                raw.flush()
                metadata["bytes_received"] += len(data)
                last_rx = last_gap = time.monotonic()
                pending += data
                while b"\n" in pending:
                    line, pending = pending.split(b"\n", 1)
                    # Keep each received LF-delimited payload byte-for-byte.
                    record(line)
                    metadata["serial_lines"] += 1
                    text = line.strip(b"\r").decode("ascii", errors="replace")
                    match = re.search(r"^MMT_DEC t=(\d+)", text)
                    if match:
                        metadata["last_device_ms"] = int(match[1])
                    if text.startswith("MMT_LIVE_BOOT"):
                        metadata["live_boot_lines"].append(text)
                    if text.startswith("MMT_CAM"):
                        metadata["camera_lines"].append(text)
                if metadata["serial_lines"] % 100 < 10:
                    save()
            metadata["completed"] = True
        except BaseException as exc:
            metadata["error"] = repr(exc)
            record("### CAPTURE_ERROR " + repr(exc))
            raise
        finally:
            if pending:
                record("### CAPTURE_END_PARTIAL_HEX " + pending.hex())
            if port is not None:
                port.close()
            metadata["ended_wall"] = wall()
            if metadata["connected_wall"]:
                metadata["connected_duration_seconds"] = (
                    dt.datetime.fromisoformat(metadata["ended_wall"]) -
                    dt.datetime.fromisoformat(metadata["connected_wall"])).total_seconds()
            record("### CAPTURE_END lines=%d gaps=%d reconnects=%d completed=%s" % (
                metadata["serial_lines"], metadata["gaps"], metadata["reconnects"], metadata["completed"]))
            save()
            print("CAPTURE_FINISHED", json.dumps(metadata, ensure_ascii=False), flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--port", default="COM15")
    parser.add_argument("--seconds", type=float, default=600)
    parser.add_argument("--resume", action="store_true", help="Append to the same log after a host reader restart")
    args = parser.parse_args()
    if args.seconds <= 0:
        parser.error("--seconds must be positive")
    sys.path.append(r"D:\Efinity\2026.1\python311\Lib\site-packages")
    import serial
    capture(args, serial)


if __name__ == "__main__":
    main()
