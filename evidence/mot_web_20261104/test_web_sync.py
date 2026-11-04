"""No board required: exact grayscale, aspect and immutable PC/FPGA pairs."""
import ast,copy,json,struct,threading,time,urllib.request,urllib.parse,urllib.error,zlib,sys
from pathlib import Path
root=Path(__file__).absolute().parents[2]
sys.path.insert(0,str(root/'tools'))
from preview_protocol import decode_preview_packet,encode_preview_packet
tree=ast.parse((root/'tools/web_monitor.py').read_text(encoding='utf8'))
names={'BoardHTTPMirror','png_gray','decode_udp_pixels','png_preview'}
exec(compile(ast.Module(body=[n for n in tree.body if isinstance(n,(ast.FunctionDef,ast.ClassDef)) and n.name in names],type_ignores=[]),'web_functions','exec'))
checks=[]
raw=bytes(range(256));legacy=bytes(x^128 for x in raw)
assert decode_udp_pixels(legacy,'legacy-offset128')==raw
assert decode_udp_pixels(raw,'uint8')==raw
checks+=['all 256 legacy grayscale levels recovered exactly','new firmware raw pixels unchanged']
pixels=bytes((x+y*96)%256 for y in range(96) for x in range(96))
png=png_preview(pixels,96,96,'uint8')
assert struct.unpack('>II',png[16:24])==(384,216)
pos=8;compressed=b''
while pos<len(png):
    n=int.from_bytes(png[pos:pos+4],'big');kind=png[pos+4:pos+8];data=png[pos+8:pos+8+n]
    assert zlib.crc32(kind+data)==int.from_bytes(png[pos+8+n:pos+12+n],'big')
    if kind==b'IDAT':compressed+=data
    pos+=n+12
actual=zlib.decompress(compressed)
expected=b''.join(b'\0'+bytes(pixels[(y*96//216)*96+x*96//384] for x in range(384)) for y in range(216))
assert actual==expected
checks+=['384x216 physical aspect','PNG CRC and every decoded preview pixel']
mirror=BoardHTTPMirror('http://169.254.47.63')
seq=12
def read(path,limit):
    if path=='/api/preview':raise urllib.error.HTTPError(path,404,'legacy firmware',{},None)
    if path=='/api/state':return json.dumps({'f':123,'obs':2,'tracking':{'frame_id':seq,'people_count':2,'frame_url':'/frame.png?seq='+str(seq),'tracks':[]}}).encode()
    assert path=='/frame.png?seq='+str(seq)
    return png
mirror.read=read;mirror.poll_once()
state=mirror.snapshot()
assert state['tracking']['people_count']==2 and state['tracking']['frame_aligned']
assert state['tracking']['frame_url']=='/snapshot/frame.png?seq=12'
assert mirror.image('12')==png
state['tracking']['people_count']=99
assert mirror.snapshot()['tracking']['people_count']==2
checks+=['PC uses authoritative board people count','matched image token and pixels','browser mutations cannot corrupt cached snapshot']
for seq in range(13,24):mirror.poll_once()
assert len(mirror.frames)==8 and mirror.image('12') is None and mirror.image('23')==png
checks+=['bounded cache expires old images rather than substituting latest frame']
mirror.updated-=11
assert mirror.snapshot()['connected'] is False
checks+=['stale upstream explicitly disconnected']
result={'passed':True,'checks':checks}
Path(__file__).with_name('web_sync_test.json').write_text(json.dumps(result,indent=2),encoding='utf8')
print(json.dumps(result))
