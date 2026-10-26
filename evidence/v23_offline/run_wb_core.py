"""Compile only a standalone algorithm test, then execute RV32IM under Unicorn.

This script has no board, UART, flashing, or main_live firmware build path.
Install unicorn into a separate work directory and pass --vendor if needed.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys


def run(a):
    if a.vendor:
        sys.path.insert(0, str(a.vendor.resolve()))
    from unicorn import Uc, UC_ARCH_RISCV, UC_MODE_RISCV32, __version__
    from unicorn.riscv_const import UC_RISCV_REG_SP, UC_RISCV_REG_RA, UC_RISCV_REG_A0, UC_RISCV_REG_PC
    here = Path(__file__).resolve().parent
    a.work.mkdir(parents=True, exist_ok=True)
    a.out.mkdir(parents=True, exist_ok=True)
    elf, binary = a.work / "wb_core.elf", a.work / "wb_core.bin"
    gcc = a.toolchain / "riscv-none-elf-gcc.exe"
    command = [str(gcc), "-std=c99", "-O2", "-Wall", "-Wextra", "-Werror", "-march=rv32im",
               "-mabi=ilp32", "-msmall-data-limit=0", "-mno-relax", "-ffreestanding",
               "-fno-builtin", "-nostdlib", "-Wl,--no-relax,-Ttext=0x10000,--entry=wb_selftest",
               str(here / "test_wb_estimator.c"), "-lgcc", "-o", str(elf)]
    env = os.environ.copy()
    env.pop("PYTHONHOME", None)
    build = subprocess.run(command, capture_output=True, env=env, timeout=60)
    (a.out / "wb_core_build.log").write_bytes(build.stdout + build.stderr)
    build.check_returncode()
    subprocess.run([str(a.toolchain / "riscv-none-elf-objcopy.exe"), "-O", "binary", str(elf), str(binary)], check=True, timeout=20)
    nm = subprocess.run([str(a.toolchain / "riscv-none-elf-nm.exe"), "-n", str(elf)], capture_output=True, text=True, check=True)
    entry = int(next(line.split()[0] for line in nm.stdout.splitlines() if line.endswith(" wb_selftest")), 16)
    code = binary.read_bytes()
    emulator = Uc(UC_ARCH_RISCV, UC_MODE_RISCV32)
    emulator.mem_map(0x10000, 0x40000)
    emulator.mem_write(0x10000, code)
    emulator.mem_map(0x800000, 0x10000)
    emulator.reg_write(UC_RISCV_REG_SP, 0x80FFF0)
    emulator.reg_write(UC_RISCV_REG_RA, 0x4FFF0)
    emulator.emu_start(entry, 0x4FFF0, count=2000000)
    result = {"unicorn_version": __version__, "architecture": "RV32IM",
              "return_code": emulator.reg_read(UC_RISCV_REG_A0),
              "returned_to_sentinel": emulator.reg_read(UC_RISCV_REG_PC) == 0x4FFF0,
              "properties": 12, "binary_sha256": hashlib.sha256(code).hexdigest(),
              "board_access": False, "firmware_image_built": False,
              "candidate_integrated": False, "hardware_writes": False}
    (a.out / "wb_core_result.json").write_text(json.dumps(result, indent=2)+"\n", encoding="utf-8", newline="\n")
    print(json.dumps(result))
    if result["return_code"] != 0 or not result["returned_to_sentinel"]:
        raise SystemExit(1)


if __name__ == "__main__":
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--toolchain", type=Path, default=Path(r"D:\riscv\xpack-riscv-none-elf-gcc-15.2.0-1\bin"))
    p.add_argument("--vendor", type=Path)
    p.add_argument("--work", type=Path, required=True)
    p.add_argument("--out", type=Path, required=True)
    run(p.parse_args())
