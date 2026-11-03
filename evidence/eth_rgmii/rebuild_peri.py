# -*- coding: utf-8 -*-
"""rebuild peri: GE pins inserted right after the last comp_gpio (before global_unused_config / bus), buses appended with the others."""
import re, pathlib
src = pathlib.Path(r'D:\v30_build\m17\ti60f225_oob.peri.xml')
dst = pathlib.Path(r'D:\eth_build\m17_ge\ti60f225_oob.peri.xml')
DEMO = pathlib.Path(r'D:\eth_build\ge\led_test.peri.xml')
lines = src.read_text(encoding='utf-8').split('\n')
demo = DEMO.read_text(encoding='utf-8')

def block(name):
    m = re.search(r'( *<efxpt:comp_gpio name="%s".*?</efxpt:comp_gpio>)' % re.escape(name), demo, re.S)
    assert m, name
    return m.group(1).split('\n')

names = ['rxc', 'rx_dv', 'rxd[0]', 'rxd[1]', 'rxd[2]', 'rxd[3]',
         'txc', 'tx_en_o', 'txd[0]', 'txd[1]', 'txd[2]', 'txd[3]', 'phy_rst_n']
ge_lines = []
for n in names:
    ge_lines += [l.rstrip('\r') for l in block(n)]

# 1) 插入到最后一个 </efxpt:comp_gpio> 之后
last_idx = max(i for i, l in enumerate(lines) if '</efxpt:comp_gpio>' in l)
lines[last_idx+1:last_idx+1] = ge_lines

# 2) bus 声明追加到其它 bus 之后
bus_idx = max(i for i, l in enumerate(lines) if '<efxpt:bus ' in l)
lines[bus_idx+1:bus_idx+1] = ['        <efxpt:bus name="rxd" mode="input" msb="3" lsb="0"/>',
                              '        <efxpt:bus name="txd" mode="output" msb="3" lsb="0"/>']

# 3) PLL
m = re.search(r'( *<efxpt:pll name="ge_0_gclk_pll".*?</efxpt:pll>)', demo, re.S)
pll = [l.rstrip('\r').replace('pll_def="PLL_TR0"', 'pll_def="PLL_TR1"') for l in m.group(1).split('\n')]
pll_idx = max(i for i, l in enumerate(lines) if '</efxpt:pll>' in l)
lines[pll_idx+1:pll_idx+1] = pll

dst.write_text('\n'.join(lines), encoding='utf-8')
print('rebuilt peri: +%d pin lines, +2 bus, PLL_TR1' % len(ge_lines))
