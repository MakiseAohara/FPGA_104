import pathlib
p = pathlib.Path(r'D:\eth_build\m17_ge\ti60f225_oob.xml')
lines = p.read_bytes().split(b'\n')
if not any(b'ge_udp_rx_bridge.v' in l for l in lines):
    i = next(k for k, l in enumerate(lines) if b'<efx:top_vhdl_arch' in l)
    lines.insert(i, b'        <efx:design_file name="rtl/ge/ge_udp_rx_bridge.v" version="default" library="default"/>')
    p.write_bytes(b'\n'.join(lines))
print('project updated')
