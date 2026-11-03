# -*- coding: utf-8 -*-
"""merge_ge2.py - 只做 peri 引脚/PLL 与工程文件表（top.v 已单独打好）。"""
import re, pathlib
ROOT = pathlib.Path(r'D:\eth_build\m17_ge')
DEMO = pathlib.Path(r'D:\eth_build\ge')
peri_p = ROOT / 'ti60f225_oob.peri.xml'
prj_p = ROOT / 'ti60f225_oob.xml'
peri = peri_p.read_text(encoding='utf-8')
demo = (DEMO / 'led_test.peri.xml').read_text(encoding='utf-8')
if 'ge_0_gclk_pll' in peri:
    print('peri already patched')
else:
    def block(src, name):
        m = re.search(r'( *<efxpt:comp_gpio name="%s".*?</efxpt:comp_gpio>\n)' % re.escape(name), src, re.S)
        if not m:
            raise SystemExit('block not found: ' + name)
        return m.group(1)
    names = ['rxc', 'rx_dv', 'rxd[0]', 'rxd[1]', 'rxd[2]', 'rxd[3]',
             'txc', 'tx_en_o', 'txd[0]', 'txd[1]', 'txd[2]', 'txd[3]', 'phy_rst_n']
    add = ''.join(block(demo, n) for n in names)
    add += '        <efxpt:bus name="rxd" mode="input" msb="3" lsb="0"/>\n'
    add += '        <efxpt:bus name="txd" mode="output" msb="3" lsb="0"/>\n'
    peri = peri.replace('    </efxpt:gpio_info>', add + '    </efxpt:gpio_info>', 1)
    m = re.search(r'( *<efxpt:pll name="ge_0_gclk_pll".*?</efxpt:pll>\n)', demo, re.S)
    pll = m.group(1).replace('pll_def="PLL_TR0"', 'pll_def="PLL_TR1"')
    peri = peri.replace('    </efxpt:pll_info>', pll + '    </efxpt:pll_info>', 1)
    peri_p.write_text(peri, encoding='utf-8')
    print('peri patched: +%d gpio, +1 pll' % len(names))
prj = prj_p.read_text(encoding='utf-8')
want = [p.relative_to(ROOT).as_posix() for p in sorted((ROOT / 'rtl' / 'ge').rglob('*.v'))]
ins = ''
for w in want:
    if 'name="%s"' % w in prj:
        continue
    ins += '        <efx:design_file name="%s" version="default" library="default"/>\n' % w
if ins:
    prj = prj.replace('    </efx:design_info>', ins + '    </efx:design_info>', 1)
    prj_p.write_text(prj, encoding='utf-8')
print('project xml: +%d files, total ge=%d' % (ins.count('<efx:design_file'), len(want)))
