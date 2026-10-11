#!/usr/bin/env python3
"""
tinyml_res_estimate.py -- run Efinix's own TinyML resource estimator headlessly.

The TinyML Generator ships a GUI (tools/tinyml_generator/tinyml_generator.py)
plus the actual resource model in tools/tinyml_generator/lib/resource_lib.py.
The GUI is a pain to drive, but the model is plain Python, so we can import it
and evaluate a configuration directly -- that is what this script does.

It deliberately does NOT re-implement any formula: it calls
ResourceUtil.evaluate_res() / evaluate_common_module() exactly like
tinyml_generator.py:381-399 does, so the numbers are the vendor's own.

Usage:
    python tinyml_res_estimate.py --repo D:\\FPGA\\tinyml \\
        --define <path to tinyml_core0_define.v> [--axi-dw 128]

If --define is omitted it uses the Ti60F225 mobilenetv1 person-detect demo.

Column order (from tinyml_generator.py:380):
    LUTs, FFs, ADDs, RAM Blocks, DSP Blocks
"""

import argparse
import os
import re
import sys

# ---------------------------------------------------------------- parse define
DEFINE_RE = re.compile(r'`define\s+(\S+)\s+(.*)')


def parse_define(path, core=0):
    """Read tinyml_coreN_define.v into a plain dict of name -> value (str)."""
    out = {}
    with open(path, 'r', encoding='utf-8', errors='replace') as fh:
        for line in fh:
            m = DEFINE_RE.search(line)
            if not m:
                continue
            name, val = m.group(1), m.group(2).strip()
            val = val.split('//')[0].strip()          # drop trailing comment
            val = val.strip('"')                      # strings are quoted
            out[name] = val
    return out


def to_python_param(d):
    """Map `TML_C0_FOO` defines onto the key names resource_lib expects."""
    p = {}
    for k, v in d.items():
        kk = k
        if kk.startswith('TML_C0_'):
            kk = kk[len('TML_C0_'):]
        p[kk] = v
    # resource_lib reads p[name]['val']
    return {k: {'val': v} for k, v in p.items()}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--repo', default=r'D:\FPGA\tinyml')
    ap.add_argument('--define', default=None)
    ap.add_argument('--axi-dw', type=int, default=None)
    args = ap.parse_args()

    if args.define is None:
        args.define = os.path.join(
            args.repo, 'tinyml_vision', 'Ti60F225_mobilenetv1_person_detect_demo',
            'source', 'tinyml', 'tinyml_core0_define.v')

    libdir = os.path.join(args.repo, 'tools', 'tinyml_generator', 'lib')
    if not os.path.isdir(libdir):
        print('!! resource_lib.py not found under ' + libdir)
        return 1
    sys.path.insert(0, libdir)
    import resource_lib

    d = parse_define(args.define)
    p2 = to_python_param(d)
    if args.axi_dw is not None:
        p2['AXI_DW'] = {'val': args.axi_dw}

    print('config file : ' + args.define)
    print('AXI_DW      : %s' % p2.get('AXI_DW', {}).get('val'))
    print()

    ru = resource_lib.ResourceUtil()
    ru.initialize_param(p2)

    # Same iteration as tinyml_generator.py:381-391:
    # only modules that exist in the lookup table and are not DISABLE count.
    layer_mode = []
    total = [0, 0, 0, 0, 0]
    rows = []
    for name in resource_lib.lookup_table:
        if name not in p2:
            continue
        val = p2[name]['val']
        if val == 'DISABLE':
            continue
        layer_mode.append(val)
        r = ru.evaluate_res(name, val)
        for i in range(5):
            total[i] += r[i]
        rows.append((name, r))

    common = ru.evaluate_common_module(layer_mode)
    if common:
        for i in range(5):
            total[i] += common[i]
        rows.append(('COMMON', common))

    hdr = ('%-34s %8s %8s %8s %8s %8s' %
           ('Layer/Module', 'LUTs', 'FFs', 'ADDs', 'RAM', 'DSP'))
    print(hdr)
    print('-' * len(hdr))
    for name, r in rows:
        print('%-34s %8d %8d %8d %8d %8d' % tuple([name] + r))
    print('-' * len(hdr))
    print('%-34s %8d %8d %8d %8d %8d' % tuple(['TINYML_ACCELERATOR'] + total))
    print()

    # ---- compare against the Ti60F225 budget ----
    # Ti60F225 totals, and what the MMT project already uses (measured by
    # Efinity 2026.1.132 place report, see README section 3 / 协作日志).
    BUDGET = {'LUTs': 60800, 'RAM': 256, 'DSP': 160}
    USED = {'LUTs': 20428, 'RAM': 116, 'DSP': 12}
    # NB: XLR is Efinity's logic unit; a LUT4 and a LUT4+FF each cost one XLR,
    # so LUTs+FFs is a pessimistic proxy for the XLR cost of new logic.
    logic = total[0] + total[1]
    print('budget check (Ti60F225: 60800 XLR / 256 BRAM / 160 DSP)')
    print('  accelerator logic  : %d LUTs + %d FFs -> at most %d XLR' %
          (total[0], total[1], logic))
    print('  accelerator RAM    : %d blocks   (free: %d)' % (total[3], BUDGET['RAM'] - USED['RAM']))
    print('  accelerator DSP    : %d blocks   (free: %d)' % (total[4], BUDGET['DSP'] - USED['DSP']))
    print('  current design     : %d XLR / %d RAM / %d DSP' %
          (USED['LUTs'], USED['RAM'], USED['DSP']))
    worst = USED['LUTs'] + logic
    print('  worst-case total   : %d XLR / 60800  (%.2f%%)' % (worst, 100.0 * worst / 60800))
    print('  verdict            : %s' %
          ('FITS' if (worst <= 60800 and
                      total[3] <= BUDGET['RAM'] - USED['RAM'] and
                      total[4] <= BUDGET['DSP'] - USED['DSP']) else 'DOES NOT FIT'))
    return 0


if __name__ == '__main__':
    sys.exit(main())
