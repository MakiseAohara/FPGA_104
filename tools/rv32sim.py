#!/usr/bin/env python3
"""
rv32sim.py -- a small RV32IM bare-metal emulator, for testing firmware
              that has no board to run on.

WHY THIS EXISTS
---------------
This project has no host C compiler and no RISC-V emulator installed
(checked: gcc/clang/cl/tcc all absent; only the riscv-none-elf cross
toolchain exists).  That means every line of `sw/` and every ported vendor
library is, so far, only known to *compile*.  Nothing has ever been *run*.

A bare-metal RV32 program is a small, closed world: load a flat image, start
at the entry symbol, execute.  That is small enough to emulate faithfully in
a few hundred lines of Python, and it turns "it compiles" into "it produces
these exact numbers" -- which is the difference between hoping and knowing.

SCOPE / LIMITS (read before trusting it)
----------------------------------------
  * RV32IM only: no compressed (C), no atomics (A), no float (F/D).
    Build the target with -march=rv32im -mabi=ilp32 and it will match.
  * Little endian, no MMU, no caches, no interrupts/exceptions beyond a
    trap on ECALL/EBREAK and on unmapped access.
  * MMIO is modelled as traps: see MMIO_HOOKS.  That is how the test
    programs "print" and how the MLX90640 I2C stub is answered.
  * It is an *interpreter*: expect ~1e6 instructions/second in CPython, so
    keep test programs small.  A full Melexis CalculateTo over 768 pixels
    is a few hundred thousand instructions -- fine.

Usage:
    python rv32sim.py --bin prog.bin --base 0x0 --entry 0x0 [--max 50_000_000]

The companion helper `build_rv32_test.ps1` wraps the toolchain calls
(objcopy to a flat binary, nm for symbols) so callers do not have to.
"""

import argparse
import struct
import sys

# ---------------------------------------------------------------------------
# MMIO: address -> callable(sim, addr, width, is_write, value)
# Everything not listed here is plain RAM.
# ---------------------------------------------------------------------------
MMIO_BASE = 0xF0000000
MMIO_END = 0xF0FFFFFF


class Trap(Exception):
    pass


class Halt(Exception):
    def __init__(self, code):
        self.code = code


class Sim:
    def __init__(self, mem_size=1 << 20, verbose=False):
        self.mem = bytearray(mem_size)
        self.reg = [0] * 32          # x0..x31
        self.pc = 0
        self.cycles = 0
        self.verbose = verbose
        self.out = []                # captured stdout (list of str)
        self.mmio = {}               # addr -> handler
        self.mmio_log = []
        self.exit_code = 0
        self.trace_lo = None         # PC range to trace (inclusive)
        self.trace_hi = None
        self.trace_max = 200
        self.trace_n = 0

    # ---------------------------------------------------------------- memory
    def _check(self, addr, size):
        if MMIO_BASE <= addr <= MMIO_END or MMIO_BASE <= addr + size - 1 <= MMIO_END:
            return
        if addr < 0 or addr + size > len(self.mem):
            raise Trap('unmapped access at 0x%08X (size %d)' % (addr & 0xFFFFFFFF, size))

    def load(self, addr, size):
        h = self.mmio.get(addr & 0xFFFFFFFC)
        if h is not None and addr >= MMIO_BASE:
            # handlers deal in 32-bit words; narrow accesses are derived
            w = h(self, addr, 4, False, 0)
            shift = (addr & 3) * 8
            v = (w >> shift) & ((1 << (size * 8)) - 1)
            if size == 1:
                return v
            if size == 2:
                return v
            return v & 0xFFFFFFFF
        self._check(addr, size)
        if size == 1:
            return self.mem[addr]
        if size == 2:
            return struct.unpack_from('<H', self.mem, addr)[0]
        return struct.unpack_from('<I', self.mem, addr)[0]

    def store(self, addr, size, value):
        h = self.mmio.get(addr & 0xFFFFFFFC)
        if h is not None and addr >= MMIO_BASE:
            h(self, addr, size, True, value)
            return
        self._check(addr, size)
        if size == 1:
            self.mem[addr] = value & 0xFF
        elif size == 2:
            struct.pack_into('<H', self.mem, addr, value & 0xFFFF)
        else:
            struct.pack_into('<I', self.mem, addr, value & 0xFFFFFFFF)

    def read_cstr(self, addr, limit=4096):
        out = []
        for i in range(limit):
            b = self.mem[addr + i]
            if b == 0:
                break
            out.append(chr(b))
        return ''.join(out)

    # ---------------------------------------------------------------- helpers
    @staticmethod
    def _sx(v, bits):
        m = 1 << (bits - 1)
        return (v ^ m) - m

    def _wr(self, rd, v):
        if rd:
            self.reg[rd] = v & 0xFFFFFFFF

    # ---------------------------------------------------------------- run
    def run(self, max_cycles=50_000_000):
        r = self.reg
        mem = self.mem
        while self.cycles < max_cycles:
            self.cycles += 1
            pc = self.pc
            if pc + 4 > len(mem):
                raise Trap('pc out of range: 0x%08X' % pc)
            insn = struct.unpack_from('<I', mem, pc)[0]
            self.pc = (pc + 4) & 0xFFFFFFFF
            if self.trace_lo is not None and self.trace_lo <= pc <= self.trace_hi \
                    and self.trace_n < self.trace_max:
                self.trace_n += 1
                sys.stderr.write('  pc=%08X insn=%08X  a0=%08X a1=%08X a2=%08X a3=%08X a4=%08X a5=%08X a6=%08X a7=%08X\n'
                                 % (pc, insn, r[10], r[11], r[12], r[13], r[14], r[15], r[16], r[17]))
            op = insn & 0x7F
            rd = (insn >> 7) & 0x1F
            f3 = (insn >> 12) & 7
            rs1 = (insn >> 15) & 0x1F
            rs2 = (insn >> 20) & 0x1F
            a = r[rs1]
            b = r[rs2]

            # ---- LUI / AUIPC
            if op == 0x37:
                self._wr(rd, insn & 0xFFFFF000)
            elif op == 0x17:
                self._wr(rd, (pc + self._sx(insn & 0xFFFFF000, 32)) & 0xFFFFFFFF)

            # ---- JAL
            elif op == 0x6F:
                imm = ((insn >> 31) << 20) | (((insn >> 12) & 0xFF) << 12) | \
                      (((insn >> 20) & 1) << 11) | (((insn >> 21) & 0x3FF) << 1)
                imm = self._sx(imm, 21)
                self._wr(rd, self.pc)
                self.pc = (pc + imm) & 0xFFFFFFFF

            # ---- JALR
            elif op == 0x67:
                imm = self._sx((insn >> 20) & 0xFFF, 12)
                t = (a + imm) & 0xFFFFFFFE
                self._wr(rd, self.pc)
                self.pc = t

            # ---- branches
            elif op == 0x63:
                imm = ((insn >> 31) << 12) | (((insn >> 7) & 1) << 11) | \
                      (((insn >> 25) & 0x3F) << 5) | (((insn >> 8) & 0xF) << 1)
                imm = self._sx(imm, 13)
                sa, sb = self._sx(a, 32), self._sx(b, 32)
                take = {0: a == b, 1: a != b, 4: sa < sb, 5: sa >= sb,
                        6: a < b, 7: a >= b}.get(f3, False)
                if take:
                    self.pc = (pc + imm) & 0xFFFFFFFF

            # ---- loads
            elif op == 0x03:
                imm = self._sx((insn >> 20) & 0xFFF, 12)
                addr = (a + imm) & 0xFFFFFFFF
                if f3 == 0:
                    v = self._sx(self.load(addr, 1), 8)
                elif f3 == 1:
                    v = self._sx(self.load(addr, 2), 16)
                elif f3 == 2:
                    v = self.load(addr, 4)
                elif f3 == 4:
                    v = self.load(addr, 1)
                elif f3 == 5:
                    v = self.load(addr, 2)
                else:
                    raise Trap('bad load f3=%d at 0x%08X' % (f3, pc))
                self._wr(rd, v)

            # ---- stores
            elif op == 0x23:
                imm = ((insn >> 25) << 5) | ((insn >> 7) & 0x1F)
                imm = self._sx(imm, 12)
                addr = (a + imm) & 0xFFFFFFFF
                if f3 == 0:
                    self.store(addr, 1, b)
                elif f3 == 1:
                    self.store(addr, 2, b)
                elif f3 == 2:
                    self.store(addr, 4, b)
                else:
                    raise Trap('bad store f3=%d at 0x%08X' % (f3, pc))

            # ---- OP-IMM
            elif op == 0x13:
                imm = self._sx((insn >> 20) & 0xFFF, 12)
                sh = (insn >> 20) & 0x1F
                if f3 == 0:
                    v = (a + imm) & 0xFFFFFFFF
                elif f3 == 2:
                    v = 1 if self._sx(a, 32) < imm else 0
                elif f3 == 3:
                    v = 1 if a < (imm & 0xFFFFFFFF) else 0
                elif f3 == 4:
                    v = a ^ (imm & 0xFFFFFFFF)
                elif f3 == 6:
                    v = a | (imm & 0xFFFFFFFF)
                elif f3 == 7:
                    v = a & (imm & 0xFFFFFFFF)
                elif f3 == 1:
                    v = (a << sh) & 0xFFFFFFFF
                elif f3 == 5:
                    if (insn >> 30) & 1:
                        v = (self._sx(a, 32) >> sh) & 0xFFFFFFFF
                    else:
                        v = a >> sh
                else:
                    raise Trap('bad op-imm f3=%d' % f3)
                self._wr(rd, v)

            # ---- OP
            elif op == 0x33:
                alt = (insn >> 25) & 0x7F
                sa, sb = self._sx(a, 32), self._sx(b, 32)
                if alt == 1:                       # M extension
                    if f3 == 0:                    # MUL
                        v = (a * b) & 0xFFFFFFFF
                    elif f3 == 1:                  # MULH  (signed x signed, high)
                        v = ((sa * sb) >> 32) & 0xFFFFFFFF
                    elif f3 == 2:                  # MULHSU (signed x unsigned, high)
                        v = ((sa * b) >> 32) & 0xFFFFFFFF
                    elif f3 == 3:                  # MULHU (unsigned x unsigned, high)
                        v = ((a * b) >> 32) & 0xFFFFFFFF
                    elif f3 == 4:                  # DIV  (truncate toward zero)
                        if b == 0:
                            v = 0xFFFFFFFF
                        elif sa == -2**31 and sb == -1:
                            v = 0x80000000         # overflow -> INT_MIN
                        else:
                            q = abs(sa) // abs(sb)
                            if (sa < 0) != (sb < 0):
                                q = -q
                            v = q & 0xFFFFFFFF
                    elif f3 == 5:                  # DIVU
                        v = 0xFFFFFFFF if b == 0 else (a // b) & 0xFFFFFFFF
                    elif f3 == 6:                  # REM  (sign follows the dividend)
                        if b == 0:
                            v = a                      # rem by zero -> dividend
                        elif sa == -2**31 and sb == -1:
                            v = 0                      # overflow -> 0
                        else:
                            q = abs(sa) // abs(sb)
                            if (sa < 0) != (sb < 0):
                                q = -q
                            # NOTE: subtract q*sb with sb SIGNED.  Using the raw
                            # unsigned b here (an earlier bug) makes q*sb huge
                            # whenever sb is negative, which silently corrupts
                            # every signed remainder -- and the "%10" digit loop
                            # in printf-style code is exactly where it shows up.
                            v = (sa - q * sb) & 0xFFFFFFFF
                    elif f3 == 7:                  # REMU
                        v = a if b == 0 else (a % b) & 0xFFFFFFFF
                    else:
                        raise Trap('bad M f3=%d' % f3)
                else:
                    if f3 == 0:
                        # ★ ADD has funct7=0b0000000, SUB has funct7=0b0100000.
                        #   An earlier version had this inverted (add computed a-b
                        #   and sub produced 0xFFFFFFFF), which is catastrophic
                        #   but easy to miss: GCC emits `addi` for most address
                        #   arithmetic, so plain `add a,b,c` is rarer than you
                        #   would think, and a test that does not exercise it
                        #   stays green.
                        v = ((a - b) if alt else (a + b)) & 0xFFFFFFFF
                    elif f3 == 1:
                        v = (a << (b & 0x1F)) & 0xFFFFFFFF
                    elif f3 == 2:
                        v = 1 if sa < sb else 0
                    elif f3 == 3:
                        v = 1 if a < b else 0
                    elif f3 == 4:
                        v = a ^ b
                    elif f3 == 5:
                        v = ((sa >> (b & 0x1F)) & 0xFFFFFFFF) if alt else (a >> (b & 0x1F))
                    elif f3 == 6:
                        v = a | b
                    elif f3 == 7:
                        v = a & b
                    else:
                        raise Trap('bad OP f3=%d' % f3)
                self._wr(rd, v)

            # ---- FENCE (no-op) / SYSTEM
            elif op == 0x0F:
                pass
            elif op == 0x73:
                # ECALL / EBREAK -> treat as halt so a bare-metal program can end
                if insn == 0x00000073:
                    raise Halt(0)
                if insn == 0x00100073:
                    raise Halt(0)
                if (insn & 0xFFF) == 0x105:      # wfi
                    pass
                else:
                    raise Trap('unsupported SYSTEM insn 0x%08X' % insn)

            else:
                raise Trap('unsupported opcode 0x%02X at pc=0x%08X (insn 0x%08X)'
                           % (op, pc, insn))

        raise Trap('cycle limit %d reached (pc=0x%08X)' % (max_cycles, self.pc))


# ---------------------------------------------------------------------------
# Default MMIO: a tiny "console" so test programs can print without a UART.
#   write byte to 0xF0000000 -> stdout
#   write word to 0xF0000004 -> exit with that code
#   read  word from 0xF0000008 -> 0 (constant "not busy")
# ---------------------------------------------------------------------------
def install_console(sim):
    def h(s, addr, width, is_write, value):
        off = addr - MMIO_BASE
        if off == 0x00:
            if is_write:
                s.out.append(chr(value & 0xFF))
            return 0
        if off == 0x04:
            if is_write:
                raise Halt(value & 0xFF)
            return 0
        if off == 0x08:
            return 0
        if is_write:
            s.mmio_log.append((addr, width, value))
            return 0
        return 0
    for a in (0xF0000000, 0xF0000004, 0xF0000008):
        sim.mmio[a] = h


def load_symbols(path):
    """Read the "name addr" file written by build_rv32_test.ps1 (nm output)."""
    syms = {}
    with open(path, 'r', encoding='ascii', errors='replace') as fh:
        for line in fh:
            p = line.split()
            if len(p) >= 2:
                try:
                    syms[p[0]] = int(p[1], 16)
                except ValueError:
                    pass
    return syms


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--bin', required=True)
    ap.add_argument('--base', type=lambda x: int(x, 0), default=0)
    ap.add_argument('--entry', type=lambda x: int(x, 0), default=None,
                    help='entry PC (defaults to --base)')
    ap.add_argument('--sym', default=None,
                    help='symbol file ("name addr" per line, from nm)')
    ap.add_argument('--entry-symbol', default='_start',
                    help='symbol to start at when --sym is given')
    ap.add_argument('--gp-symbol', default='__global_pointer$',
                    help='symbol whose value initialises gp (x3), as crt0 does. '
                         'Pass an empty string to skip. Without this, any '
                         'gp-relative access in code built with -nostartfiles '
                         'lands at a bogus address (gp=0).')
    ap.add_argument('--max', type=int, default=50_000_000)
    ap.add_argument('--stack-top', type=lambda x: int(x, 0), default=0x00100000,
                    help='value loaded into sp before the entry point')
    ap.add_argument('--trace-lo', type=lambda x: int(x, 0), default=None,
                    help='start of a PC range to trace (writes to stderr)')
    ap.add_argument('--trace-hi', type=lambda x: int(x, 0), default=None)
    ap.add_argument('--trace-max', type=int, default=200)
    args = ap.parse_args()

    entry = args.entry
    syms = {}
    if args.sym:
        syms = load_symbols(args.sym)
    if entry is None and args.sym:
        if args.entry_symbol not in syms:
            sys.stderr.write('!! symbol %r not found in %s\n' % (args.entry_symbol, args.sym))
            return 3
        entry = syms[args.entry_symbol]
        # _start is often not the lowest address (helpers can be emitted first),
        # so make sure the caller knows which PC we chose.
        sys.stderr.write('[rv32sim] entry %s = 0x%08X\n' % (args.entry_symbol, entry))
    if entry is None:
        entry = args.base

    sim = Sim()
    data = open(args.bin, 'rb').read()
    if args.base + len(data) > len(sim.mem):
        sim.mem.extend(b'\x00' * (args.base + len(data) - len(sim.mem) + 4096))
    sim.mem[args.base:args.base + len(data)] = data
    install_console(sim)

    sim.pc = entry
    sim.reg[2] = args.stack_top          # sp
    # gp (x3): code linked with -nostartfiles never gets this set, because crt0
    # is what normally does it.  RISC-V linker relaxation rewrites small-data
    # accesses to gp-relative form, so leaving gp == 0 makes them hit address
    # 0 + small_offset -- which shows up as a bizarre trap like 0xFFFFFA3C
    # (i.e. -1476) far from any real data.
    if args.gp_symbol:
        if args.gp_symbol in syms:
            sim.reg[3] = syms[args.gp_symbol]
            sys.stderr.write('[rv32sim] gp <- %s = 0x%08X\n'
                             % (args.gp_symbol, syms[args.gp_symbol]))
        else:
            sys.stderr.write('[rv32sim] note: %s not found; gp left as 0\n' % args.gp_symbol)
    sim.trace_lo = args.trace_lo
    sim.trace_hi = args.trace_hi
    sim.trace_max = args.trace_max

    try:
        sim.run(args.max)
    except Halt as h:
        sim.exit_code = h.code
    except Trap as t:
        sys.stderr.write('\n*** TRAP: %s\n' % t)
        sys.stderr.write('    cycles=%d pc=0x%08X ra=0x%08X\n'
                         % (sim.cycles, sim.pc, sim.reg[1]))
        sys.stdout.write(''.join(sim.out))
        return 2

    sys.stdout.write(''.join(sim.out))
    sys.stderr.write('\n[rv32sim] halted, exit=%d, cycles=%d\n' % (sim.exit_code, sim.cycles))
    return sim.exit_code


if __name__ == '__main__':
    sys.exit(main())
