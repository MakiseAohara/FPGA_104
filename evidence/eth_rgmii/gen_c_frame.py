import zlib, struct
payload = b'MMT-RAW-TEST-' + b'0123456789abcdef' * 3 + b'END'
eth = bytes.fromhex('FFFFFFFFFFFF') + bytes.fromhex('000A3501FEC0') + b'\x08\x00'
udp_len = 8 + len(payload); ip_len = 20 + udp_len
ip = bytearray(20); ip[0]=0x45; ip[2]=(ip_len>>8)&0xFF; ip[3]=ip_len&0xFF; ip[8]=64; ip[9]=17
ip[12:16]=bytes([169,254,47,62]); ip[16:20]=bytes([169,254,47,61])
s=sum((ip[i]<<8)|ip[i+1] for i in range(0,20,2))
while s>>16: s=(s&0xFFFF)+(s>>16)
c=(~s)&0xFFFF; ip[10]=(c>>8)&0xFF; ip[11]=c&0xFF
udp=struct.pack('>HHHH',8080,8080,udp_len,0)
f=eth+bytes(ip)+udp+payload
crc=zlib.crc32(f)&0xFFFFFFFF
f=f+bytes([crc&0xFF,(crc>>8)&0xFF,(crc>>16)&0xFF,(crc>>24)&0xFF])
lines=[]
for i in range(0, len(f), 12):
    lines.append('   ' + ', '.join('0x%02X' % b for b in f[i:i+12]) + ',')
print('static const unsigned char ge_test_frame[%d] = {' % len(f))
print('\n'.join(lines))
print('};')
print('const int ge_test_len = %d;' % len(f))
