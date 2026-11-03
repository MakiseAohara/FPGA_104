import pathlib, re
p = pathlib.Path(r'D:\eth_build\m17_ge\rtl\ge\ge_top_user.v')
t = p.read_text(encoding='utf-8')
# 去掉 arbi，TX 直接接 util_gmii_to_rgmii
t = re.sub(r'   wire \[15:0\] pack_total_len;.*?\.e_txd          \(e_txd\)\);\n', '', t, flags=re.S)
t = t.replace("      .gmii_txd  (gmii_txd),\n      .gmii_tx_en(gmii_tx_en),", "      .gmii_txd  (gmii_txd),\n      .gmii_tx_en(gmii_tx_en),")
p.write_text(t, encoding='utf-8')
print('arbi removed:', 'gmii_arbi' not in t)
