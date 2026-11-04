"""Drive both connection slots with full Ethernet/IP/TCP packets, no sockets."""
import ctypes as C
import json,struct,zlib
from pathlib import Path
HERE=Path(__file__).absolute().parent
MASK=(1<<32)-1
SRC=bytes([169,254,47,62]);DST=bytes([169,254,47,63])
SM=bytes.fromhex('112233445566');DM=bytes.fromhex('000a3501fec0')
def checksum(data):
    if len(data)%2:data+=b'\0'
    total=sum(struct.unpack('!%dH'%(len(data)//2),data))
    while total>>16:total=(total&65535)+(total>>16)
    return (~total)&65535
def packet(port,seq,ack,flags,data=b'',window=4096,ip=SRC):
    tcp=struct.pack('!HHIIBBHHH',port,80,seq&MASK,ack&MASK,0x50,flags,window,0,0)+data
    cs=checksum(ip+DST+bytes([0,6])+struct.pack('!H',len(tcp))+tcp)
    tcp=tcp[:16]+struct.pack('!H',cs)+tcp[18:]
    hdr=struct.pack('!BBHHHBBH4s4s',0x45,0,20+len(tcp),0,0,64,6,0,ip,DST)
    hdr=hdr[:10]+struct.pack('!H',checksum(hdr))+hdr[12:]
    wire=(DM+SM+b'\x08\x00'+hdr+tcp).ljust(60,b'\0')
    return wire+struct.pack('<I',zlib.crc32(wire))
def decode(wire):
    assert len(wire)>=54 and checksum(wire[14:34])==0
    total=int.from_bytes(wire[16:18],'big');tcp=wire[34:14+total]
    assert checksum(wire[26:34]+bytes([0,6])+struct.pack('!H',len(tcp))+tcp)==0
    return int.from_bytes(tcp[4:8],'big'),int.from_bytes(tcp[8:12],'big'),tcp[13],tcp[(tcp[12]>>4)*4:]
def destination(wire):return wire[30:34],int.from_bytes(wire[36:38],'big')

class Server:
    def __init__(self,slots=2):
        self.lib=C.CDLL(str(HERE/f'tcp_multi_{slots}.dll'))
        self.lib.feed.argtypes=[C.c_char_p,C.c_int,C.c_void_p,C.c_int,C.c_uint32]
        self.lib.tick.argtypes=[C.c_void_p,C.c_int,C.c_uint32]
        self.lib.next_seq.restype=C.c_uint32;self.lib.unacked_seq.restype=C.c_uint32
        self.lib.reset();self.now=10;self.out=C.create_string_buffer(1800);self.clients={}
        assert self.lib.connections()==slots
    def feed(self,wire):
        self.now+=1;n=self.lib.feed(wire,len(wire),self.out,len(self.out),self.now&MASK)
        return self.out.raw[:n]
    def tick(self,elapsed=2):
        self.now+=elapsed;n=self.lib.tick(self.out,len(self.out),self.now&MASK)
        return self.out.raw[:n]
    def occupied(self):return sum(self.lib.slot_used(i)>0 for i in range(self.lib.connections()))
    def drain(self,initial=(),targets=None,hold=()):
        queue=list(initial);targets=list(targets or self.clients.values());hold=set(hold)
        for _ in range(30000):
            if queue:
                wire=queue.pop(0);client=self.clients[destination(wire)];client.receive(wire)
                if client not in hold:
                    r=client.ack()
                    if r:queue.append(r)
            else:
                if all(c.finished for c in targets):
                    for c in targets:c.validate()
                    return
                r=self.tick()
                if r:queue.append(r)
        raise AssertionError('concurrent response stalled')

class Client:
    def __init__(self,server,port,ip=SRC,window=4096,handshake=True):
        self.server=server;self.port=port;self.ip=ip;self.window=window;self.seq=1001
        self.body=bytearray();self.pending={};self.finished=False;self.path=None;self.packets=0
        server.clients[(ip,port)]=self
        self.syn=server.feed(packet(port,1000,0,2,window=window,ip=ip))
        self.accepted=bool(self.syn)
        if self.accepted:
            ss,ack,flags,data=decode(self.syn)
            assert destination(self.syn)==(ip,port) and ack==1001 and flags==0x12 and not data
            self.base=(ss+1)&MASK
            if handshake:assert not self.ack()
    def send(self,ack,flags=16,data=b''):
        return self.server.feed(packet(self.port,self.seq,ack,flags,data,self.window,self.ip))
    def request(self,path):
        self.path=path;data=('GET '+path+' HTTP/1.1\r\nHost: FPGA\r\n\r\n').encode()
        r=self.send(self.base,24,data);self.seq+=len(data)
        return r
    @property
    def ack_number(self):return (self.base+len(self.body)+(1 if self.finished else 0))&MASK
    def ack(self):return self.send(self.ack_number)
    def receive(self,wire):
        assert destination(wire)==(self.ip,self.port)
        seq,ack,flags,data=decode(wire);assert ack==self.seq
        offset=(seq-self.base)&MASK
        if data:
            self.packets+=1
            for i,value in enumerate(data):
                idx=offset+i
                if idx<len(self.body):assert self.body[idx]==value,'connection response bytes changed'
                else:self.pending[idx]=value
            while len(self.body) in self.pending:self.body.append(self.pending.pop(len(self.body)))
        if flags&1:
            assert offset==len(self.body) and not self.pending
            self.finished=True
    def validate(self):
        header,payload=bytes(self.body).split(b'\r\n\r\n',1)
        assert b'200 OK' in header
        if self.path=='/html':
            expected=bytearray(ord('a')+i%26 for i in range(20000))
            expected[:12]=b'<html><body>';expected[-14:]=b'</body></html>'
            assert b'Content-Type: text/html; charset=utf-8' in header
        else:
            expected=bytes((i*17+119)%256 for i in range(10000))
            assert b'Content-Type: application/octet-stream' in header
        assert payload==expected,'HTTP body differs from its own callback snapshot'
        assert int(header.split(b'Content-Length: ')[1].split(b'\r\n')[0])==len(expected)

checks=[]
def passed(name):checks.append(name);print('PASS',name)

s=Server();a=Client(s,50000,handshake=False);b=Client(s,50001,handshake=False)
assert a.accepted and b.accepted and s.occupied()==2
assert s.feed(packet(a.port,1000,0,2))==a.syn
assert not a.ack() and not b.ack()
passed('two simultaneous SYNs accepted; duplicate SYN uses its existing slot')

x=a.request('/html');y=b.request('/binary');a.receive(x);b.receive(y)
t1=s.tick();t2=s.tick();assert {destination(t1)[1],destination(t2)[1]}=={a.port,b.port}
a.receive(t1 if destination(t1)[1]==a.port else t2)
b.receive(t1 if destination(t1)[1]==b.port else t2)
assert not s.tick()
passed('periodic service fairly fills both two-MSS flights without ACKs')
initial=[a.ack(),b.ack()];s.drain([wire for wire in initial if wire])
assert s.occupied()==0
passed('concurrent complete HTML/binary responses own immutable copies of a shared callback buffer')

s=Server();a=Client(s,50000);b=Client(s,50001)
x=a.request('/html');y=b.request('/binary');a.receive(x)
start=s.now;s.drain([y],targets=[b],hold=[a])
assert s.now-start<500 and not a.finished and b.finished
high=s.lib.next_seq(a.port);r=s.tick(501)
assert destination(r)[1]==a.port and decode(r)[0]==a.base
assert s.lib.next_seq(a.port)==high
s.drain([r],targets=[a]);assert s.occupied()==0
passed('one unacknowledged client cannot block another; its oldest packet retransmits independently')

s=Server();a=Client(s,50000);b=Client(s,50001)
a.request('/html');b.request('/binary');s.tick();s.tick()
r1=s.tick(501);r2=s.tick()
assert {destination(r1)[1],destination(r2)[1]}=={a.port,b.port}
assert decode(r1)[0] in (a.base,b.base) and decode(r2)[0] in (a.base,b.base)
passed('simultaneous retransmission deadlines are served in round-robin order')

s=Server();a=Client(s,50000);b=Client(s,50001)
x=a.request('/html');y=b.request('/binary');a.receive(x);b.receive(y)
before=(s.lib.next_seq(a.port),s.lib.next_seq(b.port))
c=Client(s,50002);assert not c.accepted and s.occupied()==2
assert before==(s.lib.next_seq(a.port),s.lib.next_seq(b.port))
s.drain([a.ack(),b.ack()],targets=[a,b])
passed('third SYN at capacity cannot overwrite either live connection or response')

s=Server();a=Client(s,50000);b=Client(s,50001)
x=a.request('/html');y=b.request('/binary');a.receive(x);b.receive(y)
high=s.lib.next_seq(b.port)
assert not s.feed(packet(50002,1000,0,4)) and s.occupied()==2
assert not a.send(a.ack_number,4) and s.occupied()==1
assert s.lib.next_seq(b.port)==high
c=Client(s,50002);assert c.accepted and s.occupied()==2
z=c.request('/html');s.drain([b.ack(),z],targets=[b,c])
passed('RST closes only its own slot; freed slot is reusable without changing the surviving response')

s=Server();a=Client(s,50000);b=Client(s,50001)
x=a.request('/binary');y=b.request('/html')
# Complete a's response but withhold its final ACK, leaving a FIN retry pending.
queue=[x,y]
for _ in range(10000):
    if queue:
        wire=queue.pop(0);c=s.clients[destination(wire)];c.receive(wire)
        if c is a and c.finished:fin=wire;break
        r=c.ack()
        if r:queue.append(r)
    else:
        r=s.tick()
        if r:queue.append(r)
else:raise AssertionError('FIN not reached')
s.drain(queue,targets=[b],hold=[a]);assert b.finished and s.occupied()==1
r=s.tick(501);assert r==fin
assert not a.ack() and s.occupied()==0
passed('lost FIN ACK remains isolated while the other HTML transfer finishes')

s=Server();a=Client(s,50000,handshake=False);b=Client(s,50001)
y=b.request('/binary');s.drain([y],targets=[b],hold=[a])
r=s.tick(501);assert r==a.syn
assert not a.ack();s.drain([a.request('/html')],targets=[a])
passed('SYN-ACK retransmission for a half-open slot does not block the other client')

s=Server();a=Client(s,50000,window=500);b=Client(s,50001)
x=a.request('/binary');y=b.request('/html');a.receive(x);b.receive(y)
assert len(decode(x)[3])==500
r=s.tick();assert destination(r)[1]==b.port
b.receive(r);assert not s.tick()
assert (s.lib.next_seq(a.port)-s.lib.unacked_seq(a.port))&MASK==500
a.window=1000;r=a.send(a.base);assert destination(r)[1]==a.port and len(decode(r)[3])==500
s.drain([r,b.ack()])
passed('receive windows and cumulative ACK progress are independent for each connection')

s=Server();a=Client(s,50000);b=Client(s,50000,ip=bytes([169,254,47,61]))
assert a.accepted and b.accepted
s.drain([a.request('/html'),b.request('/binary')])
passed('same source port on different client IPs selects distinct connection slots')

s=Server();a=Client(s,50000);b=Client(s,50001)
for _ in range(11):s.now+=999;assert not b.ack()
c=Client(s,50002);assert c.accepted and s.occupied()==2
assert s.lib.next_seq(b.port)==b.base
s.drain([b.request('/html'),c.request('/binary')],targets=[b,c])
passed('expired idle slot is reusable while another live slot is preserved')

s=Server(slots=1);a=Client(s,50000);b=Client(s,50001)
assert a.accepted and not b.accepted
s.drain([a.request('/html')],targets=[a]);assert s.occupied()==0
b=Client(s,50001);assert b.accepted;s.drain([b.request('/binary')],targets=[b])
passed('NET_CONN_COUNT=1 rollback retains single-slot isolation and reuse')

result={'passed':True,'checks':checks,'native_size_bytes':{str(n):Server(n).lib.memory_bytes() for n in (1,2)},'hardware_measurement':False}
(HERE/'tcp_multi_test.json').write_text(json.dumps(result,indent=2),encoding='utf8')
print(json.dumps(result))
