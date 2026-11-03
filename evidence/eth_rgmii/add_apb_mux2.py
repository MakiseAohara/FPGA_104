import pathlib
p = pathlib.Path(r'D:\eth_build\m17_ge\rtl\ti60f225_oob_top.v')
lines = p.read_bytes().split(b'\n')
idx = next(i for i, l in enumerate(lines) if b"5'd17:" in l)
if not any(b"5'd27" in l for l in lines):
    lines.insert(idx, b"         5'd27, 5'd28, 5'd29, 5'd30, 5'd31: soc_apb_prdata = ge_apb_prdata;  // GE")
    p.write_bytes(b'\n'.join(lines))
    print('inserted at line', idx + 1)
else:
    print('already present')
