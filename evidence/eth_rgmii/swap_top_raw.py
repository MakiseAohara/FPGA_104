import pathlib, re
# 1) 工程里加 ge_raw_test.v
prj = pathlib.Path(r'D:\eth_build\ge\led_demo.xml')
t = prj.read_text(encoding='utf-8')
if 'ge_raw_test.v' not in t:
    t = t.replace('        <efx:design_file name="rtl/udp_test_top.v" version="default" library="default"/>',
                  '        <efx:design_file name="rtl/udp_test_top.v" version="default" library="default"/>\n'
                  '        <efx:design_file name="rtl/ge_raw_test.v" version="default" library="default"/>')
    prj.write_text(t, encoding='utf-8')
    print('project: +ge_raw_test.v')
# 2) top.v 里把 udp_test_top 换成 ge_raw_test
top = pathlib.Path(r'D:\eth_build\ge\rtl\top.v')
b = top.read_bytes()
i = b.find(b'udp_test_top  u0_udp_test_top (')
if i > 0:
    j = b.find(b'\n     );', i)
    assert j > i
    j += len(b'\n     );')
    new = (b'udp_test_top  u0_dummy ();\n' if False else b'')
    body = b"""ge_raw_test u_raw (
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
     );"""
    b = b[:i] + body + b[j:]
    top.write_bytes(b)
    print('top.v swapped to ge_raw_test')
else:
    print('udp_test_top instantiation not found')
