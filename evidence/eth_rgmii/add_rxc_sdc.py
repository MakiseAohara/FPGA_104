import pathlib
p = pathlib.Path(r'D:\eth_build\m17_ge\ti60f225_oob.sdc')
t = p.read_text(encoding='utf-8', errors='replace')
if 'name rxc' not in t and 'rxc' not in t:
    t = t.rstrip() + '\n\n# GE: RGMII 125 MHz clock from PHY\ncreate_clock -period 8.000 -name rxc [get_ports {rxc}]\n'
    p.write_text(t, encoding='utf-8')
    print('rxc clock added to sdc')
else:
    print('rxc already in sdc')
