#!/usr/bin/env python3
"""build_variants.py — 一次性编译 v16 的全部固件组合（电脑端脚本，不参与固件运行）

用法（在 Windows 上，路径按本机实际情况）：
  python build_variants.py ^
      --project   D:\\v7work\\tiny_proj ^
      --toolchain D:\\riscv\\xpack-riscv-none-elf-gcc-15.2.0-1\\bin ^
      --build-script D:\\v7work\\fw_main\\build_tinyml_firmware.py ^
      --src       main_live16.cc ^
      --out       D:\\v7work\\fw_v16\\dist

输出：
  <out>/tinyml_pdti8_v16_<variant>.bin   每个组合一个固件镜像
  <out>/manifest.csv / manifest.json     大小、CRC32、SHA256、宏配置
  <out>/build_<variant>/                 每个组合的编译目录与日志

变体（与任务书一致）：
  base        全默认（CROP_MODE=0 NORM_ON=0 STRETCH_ON=0）
  crop1       CROP_MODE=1
  crop2       CROP_MODE=2
  norm        NORM_ON=1
  crop1_norm  CROP_MODE=1 + NORM_ON=1
  crop1_stretch CROP_MODE=1 + STRETCH_ON=1
"""
import argparse
import json
import re
import shutil
import subprocess
import sys
import zlib
from pathlib import Path

VARIANTS = [
    ("base",          {}),
    ("crop1",         {"CROP_MODE": 1}),
    ("crop2",         {"CROP_MODE": 2}),
    ("norm",          {"NORM_ON": 1}),
    ("crop1_norm",    {"CROP_MODE": 1, "NORM_ON": 1}),
    ("crop1_stretch", {"CROP_MODE": 1, "STRETCH_ON": 1}),
]

# 需要按变体重写的宏（必须各出现一次）
MACRO_KEYS = ["CROP_MODE", "NORM_ON", "STRETCH_ON"]

DEFAULTS = {"CROP_MODE": 0, "NORM_ON": 0, "STRETCH_ON": 0}


def rewrite_macros(text: str, overrides: dict) -> str:
    """把 main_live16.cc 中的 #define <MACRO> <default> 行改成变体值。"""
    for key in MACRO_KEYS:
        val = overrides.get(key, DEFAULTS[key])
        pat = re.compile(r"(#define\s+%s\s+)(\d+)" % re.escape(key))
        matches = pat.findall(text)
        if len(matches) != 1:
            raise SystemExit("macro %s appears %d times in source (expect 1)" % (key, len(matches)))
        text = pat.sub(lambda m: m.group(1) + str(val), text, count=1)
    return text


def crc32_of(data: bytes) -> int:
    return zlib.crc32(data) & 0xFFFFFFFF


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--project", type=Path, required=True)
    ap.add_argument("--toolchain", type=Path, required=True)
    ap.add_argument("--build-script", type=Path, required=True)
    ap.add_argument("--src", type=Path, default=Path("main_live16.cc"))
    ap.add_argument("--headers", type=Path, default=None,
                    help="core headers dir (default: <src dir>/v16)")
    ap.add_argument("--out", type=Path, required=True)
    args = ap.parse_args()

    src = args.src.resolve()
    headers = args.headers.resolve() if args.headers else (src.parent / "v16")
    if not src.is_file():
        print("ERROR: source not found: %s" % src)
        return 2
    for h in ("preprocess_core.h", "ae_core.h", "cam_ctrl_core.h"):
        if not (headers / h).is_file():
            print("ERROR: missing header: %s" % (headers / h))
            return 2

    out = args.out.resolve()
    out.mkdir(parents=True, exist_ok=True)
    base_text = src.read_text(encoding="utf-8")

    rows = []
    failures = 0
    for name, ov in VARIANTS:
        src_dir = out / ("src_" + name)
        build_dir = out / ("build_" + name)
        if src_dir.exists():
            shutil.rmtree(src_dir)
        if build_dir.exists():
            shutil.rmtree(build_dir)
        src_dir.mkdir(parents=True, exist_ok=True)
        build_dir.mkdir(parents=True, exist_ok=True)

        variant_cc = src_dir / "main_live16.cc"
        variant_cc.write_text(rewrite_macros(base_text, ov), encoding="utf-8", newline="\n")
        for h in ("preprocess_core.h", "ae_core.h", "cam_ctrl_core.h"):
            shutil.copy2(headers / h, src_dir / h)

        cmd = [
            sys.executable, str(args.build_script),
            "--project", str(args.project),
            "--toolchain", str(args.toolchain),
            "--out", str(build_dir),
            "--main-source", str(variant_cc),
        ]
        print("=" * 70)
        print("BUILD %s  macros=%s" % (name, ov if ov else "defaults"))
        log = build_dir / "build_stdout.log"
        with open(log, "w", encoding="utf-8", errors="replace") as f:
            r = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
                               errors="replace", timeout=1800)
            f.write(r.stdout)
        if r.returncode != 0:
            tail = "\n".join((r.stdout or "").splitlines()[-8:])
            print("FAILED %s (exit=%d)\n%s" % (name, r.returncode, tail))
            rows.append({"variant": name, "status": "FAILED", "reason": tail})
            failures += 1
            continue

        bin_src = build_dir / "tinyml_pdti8.bin"
        if not bin_src.is_file():
            print("FAILED %s: build succeeded but no tinyml_pdti8.bin" % name)
            rows.append({"variant": name, "status": "FAILED", "reason": "no bin"})
            failures += 1
            continue

        data = bin_src.read_bytes()
        dst = out / ("tinyml_pdti8_v16_%s.bin" % name)
        shutil.copy2(bin_src, dst)
        import hashlib
        row = {
            "variant": name,
            "status": "OK",
            "file": dst.name,
            "size": len(data),
            "crc32": "%08X" % crc32_of(data),
            "sha256": hashlib.sha256(data).hexdigest(),
            "crop_mode": ov.get("CROP_MODE", 0),
            "norm_on": ov.get("NORM_ON", 0),
            "stretch_on": ov.get("STRETCH_ON", 0),
        }
        rows.append(row)
        print("OK %-14s size=%d crc32=%s" % (name, row["size"], row["crc32"]))

    # 清单
    csv_path = out / "manifest.csv"
    with open(csv_path, "w", encoding="utf-8", newline="") as f:
        f.write("variant,status,file,size,crc32,sha256,crop_mode,norm_on,stretch_on\n")
        for r in rows:
            if r.get("status") == "OK":
                f.write("%s,OK,%s,%d,%s,%s,%d,%d,%d\n" % (
                    r["variant"], r["file"], r["size"], r["crc32"], r["sha256"],
                    r["crop_mode"], r["norm_on"], r["stretch_on"]))
            else:
                f.write("%s,FAILED,,,,,,,\n" % r["variant"])
    (out / "manifest.json").write_text(json.dumps(rows, indent=2, ensure_ascii=False),
                                       encoding="utf-8")

    print("\n" + "=" * 70)
    print("SUMMARY: %d/%d variants built, %d failed" % (len(rows) - failures, len(rows), failures))
    for r in rows:
        if r.get("status") == "OK":
            print("  %-14s %8d B  CRC32 %s  %s" % (r["variant"], r["size"], r["crc32"], r["file"]))
        else:
            print("  %-14s FAILED: %s" % (r["variant"], r.get("reason", "")[:120]))
    print("manifest: %s" % csv_path)
    return 0 if failures == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
