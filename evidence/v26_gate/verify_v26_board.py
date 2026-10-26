"""Cross-check delivered artifacts against received bytes; no device access."""
import csv
import hashlib
import json
from pathlib import Path
import re
import sys
import zlib
from PIL import Image

root = Path(__file__).resolve().parent
lines = (root / "log_v26_gate.log").read_bytes().decode("utf-8").split("\n")
bodies = [line.split("\t", 1)[1].strip("\r") for line in lines if "\t" in line]
serial_lines = [body for body in bodies if not body.startswith("###")]
received = (root / "uart_bytes.bin").read_bytes()
tail = next((bytes.fromhex(body.split(" ", 2)[2]) for body in reversed(bodies)
             if body.startswith("### FINAL_PARTIAL_LINE_HEX ")), b"")
if tail:
    assert received.endswith(tail), "Pending reader tail differs from received bytes"
    processed = received[:-len(tail)]
else:
    processed = received
byte_lines = processed.split(b"\n")
assert byte_lines[-1] == b"", "Processed serial payload does not end at LF"
byte_lines = [line.strip(b"\r").decode("ascii", errors="replace") for line in byte_lines[:-1]]
assert byte_lines == serial_lines, "Timestamped serial lines differ from received byte stream"
assert not any(body.startswith("### EVT") for body in bodies), "Prompts must remain separate from manual labels"

candidate_start = next(i for i,body in enumerate(serial_lines) if body.startswith("MMT_LIVE_BOOT "))
serial_lines = serial_lines[candidate_start:]

kv = re.compile(r"\b([A-Za-z_][A-Za-z0-9_]*)=([^\s]+)")
dec = [dict(kv.findall(body)) for body in serial_lines if body.startswith("MMT_DEC ")]
with (root / "ticks.csv").open(encoding="utf-8", newline="") as f:
    reader = csv.DictReader(f)
    assert reader.fieldnames == ["device_ms", "motion", "area", "p", "person", "alarm", "lp"]
    ticks = list(reader)
assert len(ticks) == len(dec)
for source, tick in zip(dec, ticks):
    for raw_key, csv_key in (("t", "device_ms"), ("motion", "motion"), ("area", "area"),
                             ("person", "person"), ("alarm_req", "alarm")):
        assert source.get(raw_key, "") == tick[csv_key], (raw_key, tick["device_ms"])
with (root / "ai_samples.csv").open(encoding="utf-8", newline="") as f:
    ai = list(csv.DictReader(f))
assert len(ai) == sum(body.startswith("MMT_AI ") for body in serial_lines)

complete = []
group = None
for body in serial_lines:
    if body.startswith("MMT_IMGSTAT "):
        group = {"f": dict(kv.findall(body))["f"], "rows": {}}
    elif body.startswith("MMT_IMG ") and group is not None:
        _, y, pixels = body.split()
        group["rows"][int(y)] = bytes.fromhex(pixels)
        if set(group["rows"]) == set(range(96)):
            complete.append((group["f"], b"".join(group["rows"][i] for i in range(96))))
            group = None
with (root / "frames.csv").open(encoding="utf-8", newline="") as f:
    frames = list(csv.DictReader(f))
assert len(frames) == len(complete)
for item, (frame, pixels) in zip(frames, complete):
    assert item["f"] == frame
    with Image.open(root / item["file"]) as image:
        assert image.size == (96, 96) and image.mode == "L"
        assert image.tobytes() == pixels, item["file"]
assert len(list(root.glob("contact_sheet_p*.png"))) == (len(frames) + 39) // 40

firmware = (root / "tinyml_pdti8_v26.bin").read_bytes()
assert len(firmware) == 477722 and zlib.crc32(firmware) == 0xB7CCB8D0
assert hashlib.sha256(firmware).hexdigest().upper() == "BEF15238095C194D4A734BD9F40ED22A0BA6361F325CEB6395AAF51AF9E9828C"
with (root / "manual_events_raw.csv").open(encoding="utf-8-sig",newline="") as stream:
    manual_raw = list(csv.DictReader(stream))
with (root / "manual_timetable.csv").open(encoding="utf-8-sig",newline="") as stream:
    manual_mapped = list(csv.DictReader(stream))
assert [(r["event"],r["wall"],r["source"]) for r in manual_raw] == [(r["event"],r["wall"],r["source"]) for r in manual_mapped]
result = dict(serial_payload_matches_received_bytes=True, pending_tail_bytes=len(tail),
              dec_rows=len(ticks), actual_ai_rows=len(ai), exact_pixel_frames=len(frames),
              manual_rows_preserved=True, raw_manual_rows=len(manual_raw),firmware_crc32="B7CCB8D0",
              raw_log_sha256=hashlib.sha256((root / "log_v26_gate.log").read_bytes()).hexdigest())
(root / "verification.json").write_text(json.dumps(result, indent=2)+"\n", encoding="utf-8", newline="\n")
print(json.dumps(result))
