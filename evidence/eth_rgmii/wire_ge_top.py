import pathlib, re
tp = pathlib.Path(r'D:\eth_build\m17_ge\rtl\ti60f225_oob_top.v')
b = tp.read_bytes()
start = b.find(b'udp_test_top u0_udp_test_top (')
assert start > 0
end = b.find(b'\n);', start)
assert end > start
end += 3
new = b"""
// =====================================================================
// GE: RGMII + MAC + APB payload bridge (SoC -> UDP, UDP -> SoC)
//   APB window: paddr[6:2] = 27..31  (TXDATA/TXLEN/CTRL/STATUS/RXDATA)
// =====================================================================
wire [31:0] ge_apb_prdata;
ge_top_user u0_ge (
    .clk        (core_clk),
    .paddr      (soc_apb_paddr),
    .psel       (soc_apb_psel),
    .penable    (soc_apb_penable),
    .pwrite     (soc_apb_pwrite),
    .pwdata     (soc_apb_pwdata),
    .prdata     (ge_apb_prdata),
    .rxc        (rxc),
    .rxd_hi_i   (rxd_hi_i),
    .rxd_lo_i   (rxd_lo_i),
    .rx_dv_HI   (rx_dv_HI),
    .rx_dv_LO   (rx_dv_LO),
    .tx_en_o_HI (tx_en_o_HI),
    .tx_en_o_LO (tx_en_o_LO),
    .txc_hi_o   (txc_hi_o),
    .txc_lo_o   (txc_lo_o),
    .txd_hi_o   (txd_hi_o),
    .txd_lo_o   (txd_lo_o),
    .phy_rst_n  (phy_rst_n)
);
"""
b = b[:start] + new + b[end:]
tp.write_bytes(b)
print('top.v: udp_test_top -> ge_top_user')

# 工程文件表：加 ge_eth_apb.v / ge_top_user.v
prj = pathlib.Path(r'D:\eth_build\m17_ge\ti60f225_oob.xml')
t = prj.read_bytes().split(b'\n')
add = [b'        <efx:design_file name="rtl/ge/ge_eth_apb.v" version="default" library="default"/>',
       b'        <efx:design_file name="rtl/ge/ge_top_user.v" version="default" library="default"/>']
if not any(b'ge_top_user.v' in l for l in t):
    i = next(k for k, l in enumerate(t) if b'<efx:top_vhdl_arch' in l)
    t[i:i] = add
    prj.write_bytes(b'\n'.join(t))
    print('project: +2 files')
