# -*- coding: utf-8 -*-
"""生成一帧合法的 UDP 广播帧（含 FCS），导出成 Verilog ROM case 语句。"""
import zlib, struct

def frame(payload):
    eth = bytes.fromhex('FFFFFFFFFFFF') + bytes.fromhex('000A3501FEC0') + b'\x08\x00'
    udp_len = 8 + len(payload)
    ip_len = 20 + udp_len
    ip = bytearray(20)
    ip[0] = 0x45; ip[1] = 0x00
    ip[2] = (ip_len >> 8) & 0xFF; ip[3] = ip_len & 0xFF
    ip[4] = 0; ip[5] = 0; ip[6] = 0; ip[7] = 0
    ip[8] = 64; ip[9] = 17
    ip[10] = 0; ip[11] = 0
    ip[12:16] = bytes([169, 254, 47, 62])
    ip[16:20] = bytes([169, 254, 47, 61])
    s = 0
    for i in range(0, 20, 2):
        s += (ip[i] << 8) | ip[i + 1]
    while s >> 16:
        s = (s & 0xFFFF) + (s >> 16)
    c = (~s) & 0xFFFF
    ip[10] = (c >> 8) & 0xFF; ip[11] = c & 0xFF
    udp = struct.pack('>HHHH', 8080, 8080, udp_len, 0)
    f = eth + bytes(ip) + udp + payload
    crc = zlib.crc32(f) & 0xFFFFFFFF
    f4 = f + bytes([crc & 0xFF, (crc >> 8) & 0xFF, (crc >> 16) & 0xFF, (crc >> 24) & 0xFF])
    return f4

payload = b'MMT-RAW-TEST-' + b'0123456789abcdef' * 3 + b'END'
f = frame(payload)
print('frame bytes', len(f), 'fcs', f[-4:].hex())
lines = []
for i, b in enumerate(f):
    lines.append('        8\'d%d: rom_q = 8\'h%02X;' % (i, b))
open(r'D:\eth_build\ge\rtl\raw_rom.vh', 'w', encoding='utf-8').write(
    '// generated: %d bytes (payload %d)\n' % (len(f), len(payload)) + '\n'.join(lines) + '\n')
print('wrote raw_rom.vh')
