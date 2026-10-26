"""Replay v25 CSV inputs with unchanged extracted v19/v26 C functions."""
import argparse
import csv
import difflib
import hashlib
import importlib.util
import json
from pathlib import Path
import re
import statistics
import struct
import sys

sys.dont_write_bytecode = True
parser = argparse.ArgumentParser()
parser.add_argument("--repo", type=Path, required=True)
parser.add_argument("--work", type=Path, required=True)
parser.add_argument("--vendor", type=Path, required=True)
parser.add_argument("--toolchain", type=Path, default=Path(r"D:\riscv\xpack-riscv-none-elf-gcc-15.2.0-1\bin"))
args = parser.parse_args()
repo = args.repo.resolve()
out = repo / "evidence/v26_gate"
out.mkdir(exist_ok=True)
sys.path.insert(0, str(args.vendor.resolve()))
from unicorn import Uc, UC_ARCH_RISCV, UC_MODE_RISCV32
from unicorn.riscv_const import UC_RISCV_REG_SP, UC_RISCV_REG_RA, UC_RISCV_REG_PC
spec = importlib.util.spec_from_file_location("actual_c", repo / "evidence/v23_offline/replay_actual_c.py")
actual = importlib.util.module_from_spec(spec)
spec.loader.exec_module(actual)
baseline = repo / "evidence/v19/main_live19.cc"
original = baseline.read_text(encoding="utf-8-sig")
modified = original
for old, new in (("#define AI_P_OFF         (-40)", "#define AI_P_OFF         (-80)"),
                 ("#define AI_AREA_MAX      4000", "#define AI_AREA_MAX      20000")):
    assert modified.count(old) == 1
    modified = modified.replace(old, new, 1)
source = out / "main_live26.cc"
source.write_text(modified, encoding="utf-8", newline="\n")
diff = "".join(difflib.unified_diff(original.splitlines(True), modified.splitlines(True),
                                  fromfile="evidence/v19/main_live19.cc", tofile="evidence/v26_gate/main_live26.cc"))
(out / "parameters.patch").write_text(diff, encoding="utf-8", newline="\n")
with (repo / "evidence/v25_gate/ticks.csv").open(encoding="utf-8-sig", newline="") as f:
    ticks = list(csv.DictReader(f))
with (repo / "evidence/v25_gate/ai_samples.csv").open(encoding="utf-8-sig", newline="") as f:
    samples = list(csv.DictReader(f))
ai = {int(s["device_ms"]):s for s in samples}
assert len(ai) == len(samples) == 812 and len(ticks) == 876
raw_states = {}
for line in (repo / "evidence/v25_gate/log_v25_gate.log").read_bytes().decode("utf-8").split("\n"):
    body = line.split("\t",1)[-1].strip()
    if body.startswith("MMT_DEC "):
        fields = dict(actual.KV.findall(body))
        raw_states[int(fields["t"])] = fields


def run(version, path):
    work = args.work.resolve() / version
    build_out = out / "replay" / version
    build_out.mkdir(parents=True, exist_ok=True)
    build_args = argparse.Namespace(source=path, work=work, out=build_out, toolchain=args.toolchain)
    code, symbols, constants, functions_sha = actual.compile_model(build_args)
    emulator = Uc(UC_ARCH_RISCV, UC_MODE_RISCV32)
    emulator.mem_map(0x10000,0x40000)
    emulator.mem_write(0x10000,code)
    emulator.mem_map(0x800000,0x10000)
    emulator.reg_write(UC_RISCV_REG_SP,0x80fff0)
    rows, mismatches = [], []
    previous_lp = 0
    for i, tick in enumerate(ticks):
        t = int(tick["device_ms"])
        sample = ai.get(t)
        low = int(tick["lp"])
        if sample:
            assert int(sample["p"]) == int(tick["p"])
        assert bool(sample) == (low == 0), "Incomplete fixed-input inference schedule"
        values = [int(i == 0), int(sample["p"]) if sample else 0, int(sample is not None),
                  int(low and not previous_lp), low, int(tick["motion"]), int(tick["area"]), 0,
                  0, 0, 0, t]
        previous_lp = low
        emulator.mem_write(symbols["input_data"], struct.pack("<12i",*values))
        emulator.reg_write(UC_RISCV_REG_RA,0x4fff0)
        emulator.emu_start(symbols["replay_frame"],0x4fff0,count=20000)
        assert emulator.reg_read(UC_RISCV_REG_PC) == 0x4fff0
        alarm,cand,rel,person = struct.unpack("<4i", emulator.mem_read(symbols["output_data"],16))
        row = dict(device_ms=t, motion=int(tick["motion"]), area=int(tick["area"]),
                   infer_ran=int(sample is not None), p=int(sample["p"]) if sample else None,
                   person=person, alarm=alarm, lp=low, cand=cand, rel=rel)
        rows.append(row)
        if version == "v19":
            observed = raw_states[t]
            expected = tuple(int(observed[k]) for k in ("alarm_req","cand","rel","person"))
            if (alarm,cand,rel,person) != expected:
                mismatches.append(dict(device_ms=t, actual_c=[alarm,cand,rel,person], logged=expected))
    with (build_out / "ticks_replayed.csv").open("w", encoding="utf-8", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=list(rows[0]))
        writer.writeheader()
        writer.writerows(rows)
    intervals = []
    opened = None
    for row in rows:
        if row["alarm"] and opened is None:
            opened = row["device_ms"]
        elif not row["alarm"] and opened is not None:
            intervals.append(dict(start_ms=opened,end_ms=row["device_ms"],duration_ms=row["device_ms"]-opened))
            opened = None
    if opened is not None:
        intervals.append(dict(start_ms=opened,end_ms=None,duration_ms=None))
    gaps = [b["start_ms"]-a["end_ms"] for a,b in zip(intervals,intervals[1:]) if a["end_ms"] is not None]
    # Protocol proxy only: it is not a replacement for independent presence labels.
    first, last = rows[0]["device_ms"], rows[-1]["device_ms"]
    proxy_empty = [r for r in rows if r["device_ms"] < first+30000 or r["device_ms"] >= last-60000]
    confirmation = []
    for interval in intervals:
        if interval["end_ms"] is None:
            continue
        relevant = [r for r in rows if interval["start_ms"] <= r["device_ms"] < interval["end_ms"]
                    and r["infer_ran"] and r["p"] >= constants["AI_P_OFF"]]
        if relevant:
            confirmation.append(interval["end_ms"]-relevant[-1]["device_ms"])
    functions = {name:hashlib.sha1(actual.function(path.read_text(encoding="utf-8-sig"),name).encode()).hexdigest()
                 for name in ("ai_vote_update","ai_reset","dec_update","dec_log")}
    return rows, dict(constants=constants, source_sha256=hashlib.sha256(path.read_bytes()).hexdigest(),
                      raw_function_sha1=functions, extracted_functions_sha256=functions_sha,
                      dec_records=len(rows), compared_records=len(rows) if version=="v19" else None,
                      mismatches=mismatches, alarm_segments=len(intervals), alarm_intervals=intervals,
                      alarm_ticks=sum(r["alarm"] for r in rows),
                      total_closed_alarm_duration_ms=sum(x["duration_ms"] or 0 for x in intervals),
                      maximum_internal_alarm_off_gap_ms=max(gaps,default=None),
                      protocol_proxy_empty_ticks=len(proxy_empty), protocol_proxy_empty_alarm_ticks=sum(r["alarm"] for r in proxy_empty),
                      release_after_last_nonoff_ai_ms=dict(min=min(confirmation,default=None),
                           median=statistics.median(confirmation) if confirmation else None,max=max(confirmation,default=None)),
                      physical_presence_coverage=None, physical_presence_longest_interruption_ms=None,
                      physical_empty_alarm_ticks=None, physical_departure_release_delay_ms=None)


base_rows, base_result = run("v19",baseline)
assert not base_result["mismatches"], "v19 baseline replay mismatch; do not continue"
new_rows, new_result = run("v26",source)
assert [r["person"] for r in base_rows] == [r["person"] for r in new_rows]
result = dict(method="existing compile_model; actual extracted C executed as RV32IM under Unicorn; no full firmware build",
              inputs={p:hashlib.sha256((repo/"evidence/v25_gate"/p).read_bytes()).hexdigest() for p in ("ticks.csv","ai_samples.csv")},
              v19=base_result, v26=new_result,
              presence_labels="not found in repository or supplied inputs; person/motion are not ground truth",
              proxy_empty_definition="device_ms first tick +30s, and final tick -60s; protocol proxy, not verified presence",
              fixed_input_validity="LP uses motion/last_person, not alarm; on-vote parameters unchanged and person sequences identical",
              source_change_scope="only AI_P_OFF and AI_AREA_MAX; original IMG_DUMP_EVERY=40 and v19 boot text preserved",
              board_access=False, full_firmware_built=False)
(out / "replay_results.json").write_text(json.dumps(result,ensure_ascii=False,indent=2)+"\n",encoding="utf-8",newline="\n")
print(json.dumps({version:{key:value for key,value in result[version].items() if key not in ("alarm_intervals","raw_function_sha1","constants")}
                  for version in ("v19","v26")},ensure_ascii=False))
