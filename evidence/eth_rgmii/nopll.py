# -*- coding: utf-8 -*-
"""nopll: 去掉 GE 的 PLL，TX 直接用 rxc（125 MHz）驱动 DDIO。"""
import re, pathlib
# ---- peri ----
p = pathlib.Path(r'D:\eth_build\m17_ge\ti60f225_oob.peri.xml')
t = p.read_text(encoding='utf-8')
t = re.sub(r' *<efxpt:pll name="ge_0_gclk_pll".*?</efxpt:pll>\n', '', t, flags=re.S)
t = t.replace('clock_name="ge0_tx_clk_90"', 'clock_name="rxc"')
t = t.replace('clock_name="ge0_tx_clk"', 'clock_name="rxc"')
p.write_text(t, encoding='utf-8')
print('peri: PLL removed, TX clock -> rxc')
# ---- top ----
tp = pathlib.Path(r'D:\eth_build\m17_ge\rtl\ti60f225_oob_top.v')
b = tp.read_bytes()
b = b.replace(b'    (* syn_peri_port = 0 *) input  ge_0_gclk_pll_LOCKED,\n', b'')
b = b.replace(b'    (* syn_peri_port = 0 *) output ge_rx_pll_RSTN,\n', b'')
b = b.replace(b'assign ge_rx_pll_RSTN = 1\'b1;\n', b'')
b = b.replace(b'.rst_n                      (ge_0_gclk_pll_LOCKED),', b'.rst_n                      (1\'b1),')
tp.write_bytes(b)
print('top: ports removed, rst_n tied')
