"""load_retry.py — 反复尝试（烧位流 + UART 上传）直到 MMT_LOAD_PASS，然后连续抓取。
板上 loader 偶发在 ~30 KB 处停止 ACK（老问题），成功率约 1/3，故自动重试。
用法: py -3 -u load_retry.py --image <bin> --out <dir> --capture-seconds 240 [--attempts 8]
"""
import argparse, subprocess, sys, time

try:
    sys.stdout.reconfigure(encoding='utf-8', errors='replace')
except Exception:
    pass
from pathlib import Path

ap = argparse.ArgumentParser()
ap.add_argument('--image', type=Path, required=True)
ap.add_argument('--out', type=Path, required=True)
ap.add_argument('--bit', default=r'C:\Users\Makise Aohara\Documents\deepseek-harness\default-workspace\FPGA_104\evidence\v29_rtl_ir_rot\v7_MERGE17.bit')
ap.add_argument('--bit-sha', default='3A69AAFB0E22E262E4CA7FE887CB332822772536356B596473D996BA190887CF')
ap.add_argument('--flash-script', default=r'D:\v30_build\flash_vendor_utf8.ps1')
ap.add_argument('--capture-seconds', type=float, default=240)
ap.add_argument('--attempts', type=int, default=8)
a = ap.parse_args()

loader = Path(r'D:\v30_build\load_v30.py')
for i in range(1, a.attempts + 1):
    print(f'=== attempt {i}/{a.attempts} ===', flush=True)
    flash = subprocess.run(['powershell', '-NoProfile', '-ExecutionPolicy', 'Bypass',
                            '-File', a.flash_script, '-Bit', a.bit, '-Sha256', a.bit_sha, '-Force'],
                           capture_output=True, text=True, errors='replace', timeout=180)
    fla = (flash.stdout or '') + (flash.stderr or '')
    if 'finished with JTAG programming' not in fla and 'JTAG programming' not in fla:
        print('  flash failed:', fla[-200:].encode('ascii', 'replace').decode(), flush=True)
        time.sleep(3); continue
    r = subprocess.run([sys.executable, '-u', str(loader), '--image', str(a.image),
                        '--out', str(a.out), '--capture-seconds', '0', '--boot-timeout', '60'],
                       capture_output=True, text=True, errors='replace', timeout=300)
    out = r.stdout or ''
    print(out[-400:], flush=True)
    if 'MMT_LOAD_PASS' in out:
        print('LOAD_OK', flush=True)
        cap = subprocess.run([sys.executable, '-u', str(loader), '--no-upload',
                              '--out', str(a.out), '--capture-seconds', str(a.capture_seconds)],
                             capture_output=True, text=True, errors='replace', timeout=a.capture_seconds + 120)
        print((cap.stdout or '')[-300:], flush=True)
        print('CAPTURE_DONE', flush=True)
        sys.exit(0)
    time.sleep(2)
print('ALL_ATTEMPTS_FAILED', flush=True)
sys.exit(2)
