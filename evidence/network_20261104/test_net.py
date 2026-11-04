"""Exercise the firmware TCP implementation with real wire-format packets."""
import ctypes as C, struct, json, zlib
from pathlib import Path

ROOT=Path(__file__).resolve().parents[2]
lib=C.CDLL(str(Path(__file__).with_name('net_test.dll')))
lib.feed.argtypes=[C.c_char_p,C.c_int,C.c_void_p,C.c_int,C.c_uint32]
lib.tick.argtypes=[C.c_void_p,C.c_int,C.c_uint32]
out=C.create_string_buffer(1800)
src=bytes([169,254,47,62]);dst=bytes([169,254,47,63])
sm=bytes.fromhex('112233445566');dm=bytes.fromhex('000a3501fec0')

def checksum(b):
    if len(b)%2:b+=b'\0'
    s=sum(struct.unpack('!%dH'%(len(b)//2),b))
    while s>>16:s=(s&65535)+(s>>16)
    return (~s)&65535

def packet(seq,ack,flags,data=b'',port=40000,padding=True):
    tcp=struct.pack('!HHIIBBHHH',port,80,seq,ack,0x50,flags,4096,0,0)+data
    cs=checksum(src+dst+bytes([0,6])+struct.pack('!H',len(tcp))+tcp)
    tcp=tcp[:16]+struct.pack('!H',cs)+tcp[18:]
    ip=struct.pack('!BBHHHBBH4s4s',0x45,0,20+len(tcp),0,0,64,6,0,src,dst)
    ip=ip[:10]+struct.pack('!H',checksum(ip))+ip[12:]
    f=dm+sm+b'\x08\x00'+ip+tcp
    if padding:f=f.ljust(60,b'\0')+struct.pack('<I',zlib.crc32(f.ljust(60,b'\0')))
    return f

def feed(p,now=1):
    n=lib.feed(p,len(p),out,len(out),now)
    return out.raw[:n]

def tick(now):
    n=lib.tick(out,len(out),now)
    return out.raw[:n]

def decode(p):
    assert len(p)>=54
    assert checksum(p[14:34])==0
    total=int.from_bytes(p[16:18],'big');seg=p[34:14+total]
    assert checksum(p[26:34]+bytes([0,6])+struct.pack('!H',len(seg))+seg)==0
    return int.from_bytes(p[38:42],'big'),int.from_bytes(p[42:46],'big'),p[47],p[54:]

def transfer(path,split=False):
    lib.reset()
    syn=feed(packet(1000,0,2),10);ss,ack,flags,_=decode(syn)
    assert flags==0x12 and ack==1001
    # Lost SYN-ACK must be retransmitted even without a response body.
    assert tick(510)==syn
    assert feed(packet(1001,ss+1,16),511)==b''
    request=('GET '+path+' HTTP/1.1\r\nHost: board\r\n\r\n').encode()
    if split:
        prefix=request[:13]
        a=feed(packet(1001,ss+1,24,prefix),512)
        assert decode(a)[1]==1001+len(prefix)
        response=feed(packet(1001+len(prefix),ss+1,24,request[13:]),513)
    else:response=feed(packet(1001,ss+1,24,request),513)
    seq,ack,flags,data=decode(response)
    assert ack==1001+len(request), 'Ethernet padding must not enter TCP sequence'
    assert feed(packet(ack,seq,16),514)==b'', 'duplicate ACK advanced response'
    assert feed(packet(ack,seq+len(data),16,port=40001),515)==b'', 'foreign connection changed state'
    assert tick(1013)==response, 'lost data was not retransmitted'
    body=data;now=1014
    while True:
        nxt=seq+len(data)
        response=feed(packet(ack,nxt,16),now);now+=1
        seq2,ack2,flags2,data2=decode(response)
        assert seq2==nxt and ack2==ack
        if flags2&1:
            # FIN is also retransmitted; connection is released after ACK.
            assert tick(now+500)==response
            assert feed(packet(ack,seq2+1,16),now+501)==b''
            break
        seq,flags,data=seq2,flags2,data2;body+=data
    header,payload=body.split(b'\r\n\r\n',1)
    length=int(header.split(b'Content-Length: ')[1].split(b'\r\n')[0])
    assert len(payload)==length,(len(payload),length)
    return header,payload

header,page=transfer('/',split=True)
assert page==(ROOT/'tools/page.html').read_bytes()
print('PASS complete 11860-byte page, segmented GET, SYN/data/FIN loss, ACK and connection isolation')
_,status=transfer('/api/state');assert json.loads(status)['f']==123
print('PASS status JSON')
_,png=transfer('/frame.png?t=123');assert png.startswith(b'\x89PNG\r\n\x1a\n')
pos=8;compressed=b''
while pos<len(png):
    size=int.from_bytes(png[pos:pos+4],'big');kind=png[pos+4:pos+8];data=png[pos+8:pos+8+size]
    assert zlib.crc32(kind+data)==int.from_bytes(png[pos+8+size:pos+12+size],'big')
    if kind==b'IDAT':compressed+=data
    pos+=12+size
raw=zlib.decompress(compressed)
assert raw==b''.join(b'\0'+bytes((y*96+x)%256 for x in range(96)) for y in range(96))
print('PASS complete PNG, cache-busting query, all chunk CRCs and decompressed pixels')
header,missing=transfer('/not-found');assert b'404' in header and missing==b'not found'
lib.reset();bad=bytearray(packet(1000,0,2));bad[40]^=1
assert feed(bytes(bad))==b''
assert feed(packet(1000,0,2)[:40])==b''
print('PASS 404, corrupted checksum and truncated packet rejection')
