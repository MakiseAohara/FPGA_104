import struct, zlib, pathlib
d = pathlib.Path(r"C:\Users\Makise Aohara\Documents\deepseek-harness\default-workspace\FPGA_104\evidence\v30_mot\out_frame.png").read_bytes()
print("total", len(d), "sig", d[:8].hex())
i = 8
while i + 8 <= len(d):
    ln = struct.unpack(">I", d[i:i+4])[0]
    typ = d[i+4:i+8]
    body = d[i+8:i+8+ln]
    crc = d[i+8+ln:i+12+ln]
    ok = (len(crc) == 4 and struct.unpack(">I", crc)[0] == (zlib.crc32(typ + body) & 0xFFFFFFFF))
    print("chunk %-4s len=%d crc_ok=%s" % (typ.decode('latin1'), ln, ok))
    i += 12 + ln
    if typ == b'IEND': break
