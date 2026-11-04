import ast,copy,ctypes,json,struct,sys,threading,time,urllib.request,urllib.parse,urllib.error,zlib
from pathlib import Path
HERE=Path(__file__).absolute().parent
ROOT=HERE.parents[1];sys.path.insert(0,str(ROOT/'tools'))
from preview_protocol import decode_preview_packet,encode_preview_packet
native=ctypes.CDLL(str(HERE/'preview_http.dll'));native.reset()
native.packed_snapshot.argtypes=[ctypes.c_void_p,ctypes.c_int]
buf=ctypes.create_string_buffer(32768);n=native.packed_snapshot(buf,len(buf));assert n>9216
packet=buf.raw[:n];state,pixels=decode_preview_packet(packet)
assert state['f']==123 and state['tracking']['frame_id']==12
assert pixels==bytes(i%256 for i in range(9216))
assert decode_preview_packet(encode_preview_packet(state,pixels))==(state,pixels)
checks=['C firmware packet decoded by PC protocol','all 9216 pixels lossless, including grayscale 0..255','state and image capture IDs match','Python encode/decode contract']
for malformed in [packet[:23],packet[:-1],b'FAIL'+packet[4:],packet[:4]+b'\x02'+packet[5:],packet[:16]+struct.pack('>I',13)+packet[20:]]:
    try:decode_preview_packet(malformed)
    except (ValueError,KeyError):pass
    else:raise AssertionError('malformed packet accepted')
checks+=['truncation, format, version and capture mismatch rejected']
tree=ast.parse((ROOT/'tools/web_monitor.py').read_text(encoding='utf8'))
names={'BoardHTTPMirror','png_gray'}
exec(compile(ast.Module(body=[node for node in tree.body if isinstance(node,(ast.ClassDef,ast.FunctionDef)) and node.name in names],type_ignores=[]),'pc_mirror','exec'))
mirror=BoardHTTPMirror('http://169.254.47.63');calls=[]
def read(path,limit):calls.append(path);return packet
mirror.read=read;mirror.poll_once()
assert calls==['/api/preview']
s,raw=decode_preview_packet(mirror.packed())
assert raw==pixels and s['tracking']['frame_id']==12 and s['connected']
assert mirror.image('12').startswith(b'\x89PNG')
mirror.updated-=11
s,raw=decode_preview_packet(mirror.packed())
assert not s['connected'] and raw==pixels
checks+=['one upstream HTTP request per image','legacy PNG endpoint retained','stale mirror never claims fresh capture']
old=mirror.snapshot()
mirror.read=lambda path,limit: packet[:-1]
try:mirror.poll_once()
except ValueError:pass
else:raise AssertionError('truncated snapshot committed')
assert mirror.snapshot()['tracking']==old['tracking']
checks+=['failed transfer preserves complete last snapshot']
(HERE/'preview_packet_fixture.bin').write_bytes(packet)
result=dict(passed=True,packet_bytes=len(packet),checks=checks)
(HERE/'preview_packet_test.json').write_text(json.dumps(result,indent=2),encoding='utf8')
print(json.dumps(result))
