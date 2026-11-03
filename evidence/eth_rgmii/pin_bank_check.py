import re
from pathlib import Path
p = Path(r"D:\eth_build\m17_ge\outflow\ti60f225_oob.pinout.rpt")
rows = []
for line in p.read_text(encoding="utf-8", errors="replace").splitlines():
    if not line.startswith("|"): continue
    c = [x.strip() for x in line.strip().strip("|").split("|")]
    if len(c) < 8 or c[0] == "Pin Number" or set(c[0]) <= set("-"): continue
    rows.append(c)   # 0 pin, 1 signal, 2 pinname, 3 dir, 4 std, 5 volt, 6 bank, 7 pull, 8 func
gepat = re.compile(r"rxc|rxd_hi|rxd_lo|txd_hi|txd_lo|txc_hi|txc_lo|rx_dv|tx_en|phy_rst")
hdmi = re.compile(r"tmds", re.I)
print("== 网口引脚（-h/-l 成对共 14 根）==")
for r in rows:
    if gepat.search(r[1]):
        print("  %-5s %-26s %-12s %-14s %-8s bank %-4s" % (r[0], r[1][:26], r[3][:12], r[4][:14], r[5][:8], r[6]))
print("\n== HDMI/TMDS 引脚 ==")
for r in rows:
    if hdmi.search(r[1]):
        print("  %-5s %-26s %-12s %-14s %-8s bank %-4s" % (r[0], r[1][:26], r[3][:12], r[4][:14], r[5][:8], r[6]))
# bank 汇总
banks = {}
for r in rows:
    if r[6]:
        banks.setdefault(r[6], []).append(r)
print("\n== bank 汇总（电压/标准集合）==")
for b, rs in sorted(banks.items()):
    volts = sorted({x[5] for x in rs if x[5]})
    stds = sorted({x[4] for x in rs if x[4]})
    ge = [x[1] for x in rs if gepat.search(x[1])]
    tmd = [x[1] for x in rs if hdmi.search(x[1])]
    print("  bank %-4s 引脚 %3d 电压 %s 标准 %s" % (b, len(rs), volts, stds))
    if ge: print("      含网口: %s" % ", ".join(ge[:8]))
    if tmd: print("      含HDMI: %s" % ", ".join(tmd[:4]))
