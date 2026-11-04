"""Validated lossless Gray8 + JSON snapshot transport, shared by PC tests."""
import json,struct

MIME='application/x-mmt-preview'
HEADER=struct.Struct('>4sBBHIHHII')

def decode_preview_packet(packet):
    if len(packet)<HEADER.size:raise ValueError('Truncated preview header')
    magic,version,encoding,header_size,metadata_bytes,width,height,seq,pixel_bytes=HEADER.unpack_from(packet)
    if (magic,version,encoding,header_size)!=(b'MMTP',1,1,24):raise ValueError('Unknown preview format')
    if not 1<=width<=512 or not 1<=height<=512 or pixel_bytes!=width*height:raise ValueError('Invalid preview geometry')
    if not 2<=metadata_bytes<=12288 or len(packet)!=header_size+metadata_bytes+pixel_bytes:raise ValueError('Incomplete preview body')
    state=json.loads(packet[header_size:header_size+metadata_bytes])
    tracking=state.get('tracking',{})
    if tracking.get('frame_id')!=seq or tracking.get('width')!=width or tracking.get('height')!=height:
        raise ValueError('Preview image and tracking snapshot differ')
    return state,packet[header_size+metadata_bytes:]

def encode_preview_packet(state,pixels):
    k=state['tracking'];width,height=k['width'],k['height'];seq=k['frame_id']
    if not 1<=width<=512 or not 1<=height<=512 or len(pixels)!=width*height:raise ValueError('Invalid preview pixels')
    metadata=json.dumps(state,ensure_ascii=False,separators=(',',':')).encode('utf8')
    if not 2<=len(metadata)<=12288:raise ValueError('Preview metadata too large')
    return HEADER.pack(b'MMTP',1,1,24,len(metadata),width,height,seq,len(pixels))+metadata+pixels
