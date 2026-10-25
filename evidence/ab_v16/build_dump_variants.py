#!/usr/bin/env python3
"""Build the v16 dump-enabled variants (evidence/ab_v16).

Same macro rewrite as the repo's build_variants.py, plus:
  * IMG_DUMP_EVERY is overridden (the repo script leaves it alone)
  * an optional extra macro set (used for the AUTOEXP_ON build)
  * output binaries are named tinyml_pdti8_v16_<variant>_dump.bin

Usage:
  python build_dump_variants.py --dump-every 1
  python build_dump_variants.py --dump-every 1 --only crop1 --extra AUTOEXP_ON=1 --suffix ae
"""
import argparse
import hashlib
import json
import re
import shutil
import subprocess
import sys
import zlib
from pathlib import Path

HERE = Path(__file__).resolve().parent
SRC = HERE / "src" / "main_live16.cc"
HEADERS = HERE / "src" / "v16"
BUILD_SCRIPT = HERE / "tools" / "build_tinyml_firmware.py"
PROJECT = Path(r"D:\FPGA\codex20\official-tinyml\tinyml_hello_world\Ti60F225_tinyml_hello_world")
TOOLCHAIN = Path(r"D:\riscv\xpack-riscv-none-elf-gcc-15.2.0-1\bin")

VARIANTS = [
    ("base", {}),
    ("crop1", {"CROP_MODE": 1}),
    ("crop2", {"CROP_MODE": 2}),
    ("norm", {"NORM_ON": 1}),
    ("crop1_norm", {"CROP_MODE": 1, "NORM_ON": 1}),
    ("crop1_stretch", {"CROP_MODE": 1, "STRETCH_ON": 1}),
]
MACRO_KEYS = ["CROP_MODE", "NORM_ON", "STRETCH_ON"]
DEFAULTS = {"CROP_MODE": 0, "NORM_ON": 0, "STRETCH_ON": 0}


def set_macro(text: str, key: str, val: int) -> str:
    pat = re.compile(r"(#define\s+%s\s+)(\d+)" % re.escape(key))
    if len(pat.findall(text)) != 1:
        raise SystemExit("macro %s not unique" % key)
    return pat.sub(lambda m: m.group(1) + str(val), text, count=1)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--dump-every", type=int, required=True)
    ap.add_argument("--only", default=None, help="build a single variant")
    ap.add_argument("--extra", action="append", default=[],
                    help="extra MACRO=VALUE, e.g. AUTOEXP_ON=1")
    ap.add_argument("--suffix", default="dump", help="bin name suffix")
    ap.add_argument("--tag", default="", help="build dir tag")
    args = ap.parse_args()

    extras = {}
    for e in args.extra:
        k, v = e.split("=", 1)
        extras[k.strip()] = int(v)

    base_text = SRC.read_text(encoding="utf-8")
    rows = []
    for name, ov in VARIANTS:
        if args.only and name != args.only:
            continue
        merged = dict(ov)
        merged.update(extras)

        text = base_text
        for key in MACRO_KEYS:
            text = set_macro(text, key, merged.get(key, DEFAULTS[key]))
        text = set_macro(text, "IMG_DUMP_EVERY", args.dump_every)
        for k, v in extras.items():
            if k not in MACRO_KEYS and k != "IMG_DUMP_EVERY":
                text = set_macro(text, k, v)

        tag = args.tag or ("dump%d" % args.dump_every)
        work = HERE / "_build" / tag
        src_dir = work / ("src_" + name)
        build_dir = work / ("build_" + name)
        for d in (src_dir, build_dir):
            if d.exists():
                shutil.rmtree(d)
            d.mkdir(parents=True, exist_ok=True)

        (src_dir / "main_live16.cc").write_text(text, encoding="utf-8", newline="\n")
        # main_live16.cc uses #include "xxx_core.h" (same directory)
        v16 = src_dir / "v16"
        v16.mkdir(exist_ok=True)
        for h in ("preprocess_core.h", "ae_core.h", "cam_ctrl_core.h"):
            shutil.copy2(HEADERS / h, src_dir / h)
            shutil.copy2(HEADERS / h, v16 / h)

        cmd = [sys.executable, str(BUILD_SCRIPT),
               "--project", str(PROJECT),
               "--toolchain", str(TOOLCHAIN),
               "--out", str(build_dir),
               "--main-source", str(src_dir / "main_live16.cc")]
        print("=" * 70)
        print(f"BUILD {name}  macros={merged}  dump_every={args.dump_every}")
        r = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                           text=True, errors="replace", timeout=1800)
        (build_dir / "build_stdout.log").write_text(r.stdout or "", encoding="utf-8",
                                                    errors="replace")
        if r.returncode != 0:
            tail = "\n".join((r.stdout or "").splitlines()[-8:])
            print(f"FAILED {name} exit={r.returncode}\n{tail}")
            rows.append({"variant": name, "status": "FAILED", "reason": tail})
            continue

        bin_src = build_dir / "tinyml_pdti8.bin"
        if not bin_src.is_file():
            print(f"FAILED {name}: no bin")
            rows.append({"variant": name, "status": "FAILED", "reason": "no bin"})
            continue

        data = bin_src.read_bytes()
        out_name = f"tinyml_pdti8_v16_{name}_{args.suffix}.bin"
        (HERE / out_name).write_bytes(data)
        row = {"variant": name, "status": "OK", "file": out_name,
               "size": len(data),
               "crc32": "%08X" % (zlib.crc32(data) & 0xFFFFFFFF),
               "sha256": hashlib.sha256(data).hexdigest(),
               "dump_every": args.dump_every,
               "crop_mode": merged.get("CROP_MODE", 0),
               "norm_on": merged.get("NORM_ON", 0),
               "stretch_on": merged.get("STRETCH_ON", 0),
               "extra": extras}
        rows.append(row)
        print("OK %-14s %8d B  CRC32 %s" % (name, row["size"], row["crc32"]))

    man = HERE / ("manifest_%s.json" % (args.tag or ("dump%d" % args.dump_every)))
    man.write_text(json.dumps(rows, indent=2, ensure_ascii=False), encoding="utf-8")
    ok = sum(1 for r in rows if r["status"] == "OK")
    print(f"\nSUMMARY {ok}/{len(rows)} built -> {man.name}")
    return 0 if ok == len(rows) else 1


if __name__ == "__main__":
    sys.exit(main())
