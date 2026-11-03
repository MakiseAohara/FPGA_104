import pathlib
p = pathlib.Path(r'D:\eth_build\m17_ge\rtl\ti60f225_oob_top.v')
b = p.read_bytes()
anchor = b"         5'd17: soc_apb_prdata = {29'd0, i2c_ready_core, i2c_done_sticky, i2c_busy_core}; // I2C_STATUS\n"
assert anchor in b, 'anchor missing'
add = b"         5'd27, 5'd28, 5'd29, 5'd30, 5'd31: soc_apb_prdata = ge_apb_prdata;  // GE\n"
b = b.replace(anchor, add + anchor, 1)
p.write_bytes(b)
print('apb mux: ge words added')
