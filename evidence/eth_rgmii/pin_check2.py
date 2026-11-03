import re
from pathlib import Path
p = Path(r"D:\eth_build\m17_ge\outflow\ti60f225_oob.pinout.rpt")
rows = []
for line in p.read_text(encoding="utf-8", errors="replace").splitlines():
    if not line.startswith("|"): continue
    c = [x.strip() for x in line.strip().strip("|").split("|")]
    if len(c) < 8 or c[0] == "Pin Number" or set(c[0]) <= set("-"): continue
    rows.append(c)
print("引脚总数", len(rows))
def show(pat, label):
    print("\n== %s ==" % label)
    for r in rows:
        if re.search(pat, r[1], re.I):
            print("  %-5s %-30s %-14s %-14s %-8s bank %-4s %s" % (r[0], r[1][:30], r[3][:14], r[4][:14], r[5][:8], r[6], r[7][:12]))
show(r"rxc|rxd_hi|rxd_lo|txd_hi|txd_lo|txc_hi|txc_lo|rx_dv|tx_en|phy_rst", "网口")
show(r"i2c|sda|scl|cam_s|sns_s", "I2C / 传感器")
show(r"tmds", "HDMI")
