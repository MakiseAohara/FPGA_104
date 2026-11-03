# -*- coding: utf-8 -*-
"""把厂商 GE(RGMII) 逻辑并入 ti60f225_oob 工程：top 端口/实例化 + peri 引脚/PLL + 工程文件表。"""
import re, pathlib, sys

ROOT = pathlib.Path(r'D:\eth_build\m17_ge')
DEMO = pathlib.Path(r'D:\eth_build\ge')

top_p = ROOT / 'rtl' / 'ti60f225_oob_top.v'
peri_p = ROOT / 'ti60f225_oob.peri.xml'
prj_p = ROOT / 'ti60f225_oob.xml'

# ---------- A. top.v ----------
top = top_p.read_bytes().decode('latin-1')
if 'udp_test_top' in top:
    print('top.v already patched'); sys.exit(1)

ports = """
    (* syn_peri_port = 0 *) input  ge_0_gclk_pll_LOCKED,
    (* syn_peri_port = 0 *) output ge_rx_pll_RSTN,
    (* syn_peri_port = 0 *) input  rxc,
    (* syn_peri_port = 0 *) input  [3:0] rxd_hi_i,
    (* syn_peri_port = 0 *) input  [3:0] rxd_lo_i,
    (* syn_peri_port = 0 *) input  rx_dv_HI,
    (* syn_peri_port = 0 *) input  rx_dv_LO,
    (* syn_peri_port = 0 *) output phy_rst_n,
    (* syn_peri_port = 0 *) output tx_en_o_HI,
    (* syn_peri_port = 0 *) output tx_en_o_LO,
    (* syn_peri_port = 0 *) output txc_hi_o,
    (* syn_peri_port = 0 *) output txc_lo_o,
    (* syn_peri_port = 0 *) output [3:0] txd_hi_o,
    (* syn_peri_port = 0 *) output [3:0] txd_lo_o
"""
lines = top.split('\n')
# 找端口表结束：module 之后第一行仅含 ");"
end = next(i for i, l in enumerate(lines) if l.strip() == ');')
prev = end - 1
while lines[prev].strip() == '':
    prev -= 1
if not lines[prev].rstrip().endswith(','):
    lines[prev] = lines[prev].rstrip() + ','
lines.insert(end, ports)
top = '\n'.join(lines)

inst = """
// ===========================================================================
// Gigabit Ethernet (RGMII) - vendor GE demo logic, minimal send/echo check.
// IP/MAC/port are constants here; later they become APB registers.
// ===========================================================================
wire ge_mdc_unused, ge_mdio_o_unused, ge_mdio_oe_unused;
assign ge_rx_pll_RSTN = 1'b1;

udp_test_top u0_udp_test_top (
    .rst_n                      (ge_0_gclk_pll_LOCKED),
    .rxc                        (rxc),
    .source_mac_addr            (48'h00_0a_35_01_fe_c0),
    .TTL                        (8'h80),
    .source_ip_addr             (32'hA9FE2F3E),   // 169.254.47.62
    .destination_ip_addr        (32'hA9FE2F3D),   // 169.254.47.61 (PC APIPA)
    .udp_send_source_port       (16'h1f90),       // 8080
    .udp_send_destination_port  (16'h1f90),       // 8080
    .rxd_hi_i                   (rxd_hi_i),
    .rxd_lo_i                   (rxd_lo_i),
    .rx_dv_HI                   (rx_dv_HI),
    .rx_dv_LO                   (rx_dv_LO),
    .tx_en_o_HI                 (tx_en_o_HI),
    .tx_en_o_LO                 (tx_en_o_LO),
    .txc_hi_o                   (txc_hi_o),
    .txc_lo_o                   (txc_lo_o),
    .txd_hi_o                   (txd_hi_o),
    .txd_lo_o                   (txd_lo_o),
    .mdc_o                      (ge_mdc_unused),
    .mdio_o                     (ge_mdio_o_unused),
    .mdio_oe                    (ge_mdio_oe_unused),
    .mdio_i                     (1'b1),
    .phy_rst_n                  (phy_rst_n)
);

"""
idx = top.rstrip().rfind('endmodule')
top = top[:idx] + inst + top[idx:]
top_p.write_bytes(top.encode('latin-1'))
print('top.v patched')

# ---------- B. peri.xml ----------
peri = peri_p.read_text(encoding='utf-8')
demo = (DEMO / 'led_test.peri.xml').read_text(encoding='utf-8')

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
print('peri.xml patched: +%d gpio, +1 pll(PLL_TR1)' % len(names))

# ---------- C. 工程文件表 ----------
prj = prj_p.read_text(encoding='utf-8')
want = []
for p in sorted((ROOT / 'rtl' / 'ge').rglob('*.v')):
    want.append(p.relative_to(ROOT).as_posix())
added = 0
anchor = '    </efx:design_info>'
ins = ''
for w in want:
    if 'name="%s"' % w in prj:
        continue
    ins += '        <efx:design_file name="%s" version="default" library="default"/>\n' % w
    added += 1
prj = prj.replace(anchor, ins + anchor, 1)
prj_p.write_text(prj, encoding='utf-8')
print('project xml: +%d design_file' % added)
