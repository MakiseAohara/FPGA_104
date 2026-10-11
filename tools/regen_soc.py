#!/usr/bin/env python3
"""
regen_soc.py -- regenerate the Efinix Sapphire SoC IP from the command line.

WHY THIS EXISTS
---------------
Efinity's IP Manager is GUI-only as far as the docs go, but the GUI is just a
thin layer over plain Python: D:\\Efinity\\<ver>\\ipm\\bin\\ipm_api_service\\design.py
exposes

    IPMDesignAPI(device, family, project_path)
      .create_ip(module_name, vendor, library, name)   -> loads DEFAULT params
      .config_ip(module_name, {param: value, ...})     -> override
      .generate_ip(module_name)                        -> writes ip/<name>/

That is what this script drives. It matters for the MMT project because the
TinyML accelerator's command port hangs off the Sapphire SoC's
`cpu0_customInstruction_*` port, which only exists when the SoC parameter
`CustomInstruction` is 1 -- and our current IP was generated with it 0.

It also lets us size the on-chip RAM, which is the real constraint on how much
firmware we can run (see README section 7: the RAM is 8 KB).

SAFETY
------
Always generate into a scratch directory first and diff the result against the
IP you are currently using. This script never touches an existing IP unless you
pass --out pointing at it.

Usage:
  python regen_soc.py --out D:\\FPGA\\soc_regen_test
  python regen_soc.py --out ... --param CustomInstruction=1 --param OCRSize=65536
"""

import argparse
import os
import sys
from pathlib import Path

EFINITY_HOME = r'D:\Efinity\2026.1'
IPM_BIN = os.path.join(EFINITY_HOME, 'ipm', 'bin')


def setup_env():
    """Mirror what Efinity's bin\\setup.bat sets. Without PYTHONHOME the
    bundled interpreter dies with 'failed to get the Python codec of the
    filesystem encoding'."""
    efi = EFINITY_HOME.replace('\\', '/')
    os.environ['EFINITY_HOME'] = efi
    local = os.environ.get('LOCALAPPDATA', '').replace('\\', '/')
    os.environ.setdefault('EFINITY_USER_DIR_INI', local + '/efinity/user_dir.ini')
    os.environ.setdefault('EFINITY_USER_DIR', local + '/efinity')
    os.environ['PYTHONHOME'] = efi + '/python311'
    os.environ['EFXPT_HOME'] = efi + '/pt'
    os.environ['PATH'] = ';'.join([
        efi + '/python311/bin', efi + '/bin', efi + '/scripts',
        os.path.join(IPM_BIN), os.environ.get('PATH', '')])


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--out', required=True,
                    help='scratch project dir the IP is generated into')
    ap.add_argument('--device', default='Ti60F225')
    ap.add_argument('--family', default='Titanium')
    ap.add_argument('--name', default='sapphire_soc',
                    help='instance/module name of the IP (must match the RTL)')
    ap.add_argument('--param', action='append', default=[],
                    help='Name=Value override, repeatable. '
                         'Example: --param CustomInstruction=1')
    ap.add_argument('--hex', default=None,
                    help='firmware .bin to embed for the first boot '
                         '(relative to the IP dir or absolute)')
    ap.add_argument('--verbose', action='store_true')
    args = ap.parse_args()

    setup_env()
    sys.path.insert(0, IPM_BIN)

    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)

    print('[env ] EFINITY_HOME   = %s' % os.environ['EFINITY_HOME'])
    print('[env ] EFINITY_USER_DIR = %s' % os.environ['EFINITY_USER_DIR'])
    print('[gen ] target dir    = %s' % out)

    try:
        from ipm_api_service.design import IPMDesignAPI
    except Exception as e:
        print('!! cannot import IPMDesignAPI: %s: %s' % (type(e).__name__, e))
        return 1

    api = IPMDesignAPI(device_name=args.device, family_name=args.family,
                       project_path=str(out), is_verbose=args.verbose)

    print('[gen ] creating IP %s (efinixinc.com / soc / efx_soc) ...' % args.name)
    made = api.create_ip(args.name, 'efinixinc.com', 'soc', 'efx_soc')
    if made is None:
        print('!! create_ip returned None -- no matching IP in the library')
        return 2
    vlnv, lang = made
    print('[gen ] VLNV = %s' % vlnv)
    print('[gen ] language = %s' % lang)

    # ---- show the parameters that matter for us -------------------------
    def dump_params(api, names, title):
        params = api.get_ip_params(api._IPMDesignAPI__ips[args.name]['vlnv'],
                                   device_name=args.device, family_name=args.family) \
            if hasattr(api, 'get_ip_params') else None
        print('      (%s)' % title)

    cfg = {}
    for kv in args.param:
        if '=' not in kv:
            print('!! bad --param %r (expected Name=Value)' % kv)
            return 3
        k, v = kv.split('=', 1)
        cfg[k.strip()] = v.strip()
    if args.hex:
        cfg['HexFile_Path'] = '"%s"' % args.hex
        cfg['HexFile_PathEnable'] = "1'b1"

    if cfg:
        print('[cfg ] overrides:')
        for k, v in sorted(cfg.items()):
            print('         %-28s = %s' % (k, v))
        api.config_ip(args.name, cfg)
    else:
        print('[cfg ] no overrides -- generating with library defaults')

    print('[gen ] generating ...')
    result = api.generate_ip(args.name)
    print('[gen ] result = %s' % result)

    # ---- report what landed -------------------------------------------
    ipdir = out / 'ip' / args.name
    if not ipdir.is_dir():
        print('!! expected output dir not found: %s' % ipdir)
        return 4
    print('[out ] %s' % ipdir)
    total = 0
    for p in sorted(ipdir.rglob('*')):
        if p.is_file():
            total += 1
    print('[out ] %d files' % total)
    for p in sorted(ipdir.iterdir()):
        if p.is_file():
            print('         %-60s %d' % (p.name, p.stat().st_size))
    return 0


if __name__ == '__main__':
    sys.exit(main())
