"""Wire-format regression for the same C TCP implementation as firmware.

The latency comparison is a controlled receiver model (ACK every two packets,
200 ms delayed ACK, 2 ms service ticks), not a hardware throughput claim.
"""
import ctypes as C
import json,struct,zlib
from pathlib import Path

HERE=Path(__file__).absolute().parent
MASK=(1<<32)-1
MSS=1400
SRC=bytes([169,254,47,62]);DST=bytes([169,254,47,63])
SM=bytes.fromhex('112233445566');DM=bytes.fromhex('000a3501fec0')

def checksum(data):
    if len(data)%2:data+=b'\0'
    s=sum(struct.unpack('!%dH'%(len(data)//2),data))
    while s>>16:s=(s&65535)+(s>>16)
    return (~s)&65535

def packet(seq,ack,flags,data=b'',window=4096,port=40000):
    tcp=struct.pack('!HHIIBBHHH',port,80,seq&MASK,ack&MASK,0x50,flags,window,0,0)+data
    cs=checksum(SRC+DST+bytes([0,6])+struct.pack('!H',len(tcp))+tcp)
    tcp=tcp[:16]+struct.pack('!H',cs)+tcp[18:]
    ip=struct.pack('!BBHHHBBH4s4s',0x45,0,20+len(tcp),0,0,64,6,0,SRC,DST)
    ip=ip[:10]+struct.pack('!H',checksum(ip))+ip[12:]
    wire=(DM+SM+b'\x08\x00'+ip+tcp).ljust(60,b'\0')
    return wire+struct.pack('<I',zlib.crc32(wire))

def decode(wire):
    assert len(wire)>=54
    assert checksum(wire[14:34])==0,'IPv4 checksum'
    total=int.from_bytes(wire[16:18],'big');tcp=wire[34:14+total]
    assert checksum(wire[26:34]+bytes([0,6])+struct.pack('!H',len(tcp))+tcp)==0,'TCP checksum'
    return int.from_bytes(tcp[4:8],'big'),int.from_bytes(tcp[8:12],'big'),tcp[13],tcp[(tcp[12]>>4)*4:]

class Peer:
    def __init__(self,mode=2,size=10000,window=4096,start=10,pair=True):
        suffix='' if pair else '_nopair'
        self.lib=C.CDLL(str(HERE/f'tcp_window_{mode}{suffix}.dll'))
        self.lib.reset.argtypes=[C.c_int]
        self.lib.feed.argtypes=[C.c_char_p,C.c_int,C.c_void_p,C.c_int,C.c_uint32]
        self.lib.tick.argtypes=[C.c_void_p,C.c_int,C.c_uint32]
        self.lib.snd_nxt.restype=C.c_uint32;self.lib.snd_una.restype=C.c_uint32
        self.lib.reset(size);self.size=size;self.window=window;self.now=start
        self.out=C.create_string_buffer(1800);self.client=1001
        self.syn=self.send(packet(1000,0,2,window=window))
        self.iss,ack,flags,data=decode(self.syn)
        assert ack==1001 and flags==0x12 and not data
        self.base=(self.iss+1)&MASK;self.now+=1
        assert self.ack(self.base)==b''
        self.body=bytearray();self.pending={};self.finished=False;self.packets=0

    def send(self,wire):
        n=self.lib.feed(wire,len(wire),self.out,len(self.out),self.now&MASK)
        return self.out.raw[:n]
    def ack(self,seq,window=None,port=40000):
        if window is not None:self.window=window
        return self.send(packet(self.client,seq,16,window=self.window,port=port))
    def tick(self,elapsed=2):
        self.now+=elapsed
        n=self.lib.tick(self.out,len(self.out),self.now&MASK)
        return self.out.raw[:n]
    def request(self,split=False):
        request=b'GET /fixture HTTP/1.1\r\nHost: board\r\n\r\n'
        if split:
            prefix=request[:11]
            r=self.send(packet(self.client,self.base,24,prefix,window=self.window));self.client+=len(prefix)
            _,ack,flags,data=decode(r);assert ack==self.client and not data and flags==16
            request=request[11:]
        r=self.send(packet(self.client,self.base,24,request,window=self.window));self.client+=len(request)
        if r:assert decode(r)[1]==self.client,'padding/FCS entered receive sequence'
        return r
    def receive(self,wire):
        seq,ack,flags,data=decode(wire)
        assert ack==self.client
        offset=(seq-self.base)&MASK
        if data:
            self.packets+=1
            for i,value in enumerate(data):
                idx=offset+i
                if idx<len(self.body):assert self.body[idx]==value,'retransmit payload differs'
                else:self.pending[idx]=value
            while len(self.body) in self.pending:self.body.append(self.pending.pop(len(self.body)))
        if flags&1:
            assert offset==len(self.body) and not self.pending,'FIN before acknowledged body'
            self.finished=True
        return data
    @property
    def expected_ack(self):return (self.base+len(self.body)+(1 if self.finished else 0))&MASK
    def drain(self,initial=b''):
        wire=initial
        for _ in range(40000):
            if wire:
                self.receive(wire)
                wire=self.ack(self.expected_ack)
                if self.finished:
                    assert wire==b'';return self.validate()
            else:wire=self.tick()
        raise AssertionError('response did not finish')
    def validate(self):
        header,payload=bytes(self.body).split(b'\r\n\r\n',1)
        assert b'200 OK' in header
        assert int(header.split(b'Content-Length: ')[1].split(b'\r\n')[0])==self.size
        assert payload==bytes((i*37+11)%256 for i in range(self.size))
        return len(self.body)

checks=[]
def passed(name):checks.append(name);print('PASS',name)

# API still emits one packet per call; the next service tick can fill the flight.
p=Peer();a=p.request(split=True);b=p.tick()
assert len(decode(a)[3])==MSS and len(decode(b)[3])==MSS
assert decode(b)[0]==(decode(a)[0]+MSS)&MASK
assert p.tick()==b''
assert p.lib.snd_nxt()-p.lib.snd_una()==2*MSS
p.receive(a);p.receive(b);p.drain(p.ack(p.expected_ack))
passed('two segments emitted before ACK; complete patterned body with cumulative ACK')

for lost in (0,1):
    p=Peer();a=p.request();b=p.tick();frames=[a,b]
    p.receive(frames[1-lost]);last_ack=p.expected_ack
    r=p.ack(last_ack)
    if r:p.receive(r)
    while p.now<515:
        r=p.tick(2)
        if r:
            # Only retransmission can unblock the hole now.
            assert decode(r)[0]==last_ack
            break
    else:raise AssertionError('missing segment was not retransmitted')
    high=p.lib.snd_nxt();p.receive(r)
    assert p.lib.snd_nxt()==high,'retransmission moved snd_nxt backwards'
    p.drain(p.ack(p.expected_ack))
    passed('loss of '+('first' if lost==0 else 'second')+' segment recovers without moving snd_nxt back')

p=Peer();a=p.request();b=p.tick();first_seq,_,_,first=decode(a)
# A receiver may acknowledge only part of a segment; retain remaining bytes.
p.body.extend(first[:700]);p.receive(b)
r=p.ack((p.base+700)&MASK);assert decode(r)[0]==(p.base+2*MSS)&MASK
p.receive(r);high=p.lib.snd_nxt()
r=p.tick(500);rs,_,_,rd=decode(r)
assert rs==(p.base+700)&MASK and len(rd)==MSS
assert p.lib.snd_nxt()==high
p.receive(r);p.drain(p.ack(p.expected_ack))
passed('partial cumulative ACK retransmits exact oldest unacknowledged byte range')

p=Peer();a=p.request();b=p.tick();high=p.lib.snd_nxt()
assert p.ack(p.base)==b'' and p.lib.snd_nxt()==high
assert p.ack((high+1)&MASK)==b''
assert p.ack(high,port=40001)==b'' and p.lib.snd_una()==p.base
old=p.lib.peer_window();assert p.ack((p.base-1)&MASK,window=65535)==b''
assert p.lib.peer_window()==old
assert p.tick()==b''
passed('duplicate, future, stale and foreign-connection ACKs cannot release bytes or expand window')

p=Peer(window=1500);a=p.request();b=p.tick()
assert len(decode(a)[3])==1400 and len(decode(b)[3])==100
assert p.tick()==b'' and p.lib.snd_nxt()-p.lib.snd_una()==1500
assert p.ack(p.base,window=0)==b''
assert p.tick()==b''
high=p.lib.snd_nxt();probe=p.tick(500)
assert len(decode(probe)[3])==1 and decode(probe)[0]==p.base and p.lib.snd_nxt()==high
p.receive(a);p.receive(b);p.drain(p.ack(p.expected_ack,window=4096))
passed('small and zero peer windows bounded; only one-byte retransmit probe during zero window')

p=Peer(window=0);r=p.request();assert decode(r)[2]==16 and not decode(r)[3]
assert p.tick(100)==b''
r=p.ack(p.base,window=4096);assert decode(r)[3]
p.drain(r)
passed('initial zero window acknowledges request and resumes on window update')

p=Peer();syn=p.syn
# SYN timeout independent of whether an HTTP body already exists.
assert p.lib.segments()==2
p=Peer();p.lib.reset(10000);p.now=10
syn=p.send(packet(1000,0,2));ss,_,_,_=decode(syn)
assert p.tick(500)==syn
assert p.send(packet(1000,0,2,port=40001))==b''
p.client=1001;p.iss=ss;p.base=(ss+1)&MASK;p.ack(p.base)
a=p.request();p.receive(a)
while not p.finished:
    r=p.ack(p.expected_ack)
    if r:p.receive(r)
    else:
        r=p.tick()
        if r:p.receive(r)
fin=r
assert decode(fin)[2]&1
assert p.tick(500)==fin
assert p.ack(p.expected_ack)==b''
passed('SYN and FIN loss recover; FIN emitted only after all body bytes acknowledged')

p=Peer();a=p.request();p.tick(499) # second segment, just before oldest RTO
r=p.tick(1);assert decode(r)[0]==decode(a)[0] and decode(r)[3]==decode(a)[3]
passed('second segment sent at 499 ms does not postpone oldest retransmission')

p=Peer();bad=bytearray(packet(1000,0,2));bad[40]^=1
assert p.send(bytes(bad))==b''
assert p.send(packet(1000,0,2)[:40])==b''
passed('corrupted checksum and truncated packets rejected')

# Sequence-number wrap, including outstanding bytes on both sides of 0xffffffff.
start=((0xFFFFF800-0x1000)*pow(31,-1,1<<32))&MASK
p=Peer(start=start);a=p.request();b=p.tick();p.receive(a);p.receive(b)
p.drain(p.ack(p.expected_ack))
passed('response and cumulative ACK across 32-bit sequence wrap')

for mode in (1,2):
    p=Peer(mode=mode);first=p.request()
    if mode==1:
        assert p.tick()==b''
    p.drain(first)
passed('NET_TX_SEGMENTS=1 fallback preserves full response and stop-and-wait')

p=Peer(size=9216);p.drain(p.request())
assert p.packets<=(len(p.body)+MSS-1)//MSS+1
passed('immediate per-packet ACK cannot repeatedly subdivide the short tail')

def delayed_ack_model(mode,pair=True):
    p=Peer(mode=mode,pair=pair,size=9216);wire=p.request();start=p.now
    pending=0;due=None
    for _ in range(30000):
        if wire:
            data=p.receive(wire)
            if p.finished:
                assert p.ack(p.expected_ack)==b''
                p.validate();return dict(elapsed_ms=p.now-start,data_packets=p.packets)
            if data:
                pending+=1
                if pending>=2:due=p.now
                elif due is None:due=p.now+200
        if due is not None and p.now>=due:
            pending=0;due=None;wire=p.ack(p.expected_ack)
        else:wire=p.tick()
    raise AssertionError('delayed ACK model stalled')

latencies={'stop_and_wait':delayed_ack_model(1),'two_packet_window':delayed_ack_model(2),
           'two_packet_window_without_tail_pair':delayed_ack_model(2,pair=False)}
assert latencies['two_packet_window']['elapsed_ms']<latencies['stop_and_wait']['elapsed_ms']
assert latencies['two_packet_window']['elapsed_ms']<latencies['two_packet_window_without_tail_pair']['elapsed_ms']
passed('controlled 200 ms delayed-ACK model: two-packet flight and paired tail remove per-segment stalls')
result={'passed':True,'checks':checks,'receiver_model':{'ack_after_packets':2,'delayed_ack_ms':200,'service_tick_ms':2,'real_hardware_measurement':False},'latency_model':latencies}
(HERE/'tcp_window_test.json').write_text(json.dumps(result,indent=2),encoding='utf8')
print(json.dumps(result))
