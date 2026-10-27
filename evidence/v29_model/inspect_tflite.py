# -*- coding: utf-8 -*-
"""极简 TFLite flatbuffer 解析：读取输入/输出张量的量化参数、shape、算子清单。
不依赖 tensorflow / flatbuffers，可直接用任意 Python 3 运行。"""
import struct, sys, json, os

FT = {0:'FLOAT32',1:'FLOAT16',2:'INT32',3:'UINT8',4:'INT64',5:'STRING',6:'BOOL',
      7:'INT16',8:'COMPLEX64',9:'INT8',10:'FLOAT64',11:'COMPLEX128',12:'UINT64',
      13:'RESOURCE',14:'VARIANT',15:'UINT32',16:'UINT16'}

def u32(b,p): return struct.unpack_from('<I',b,p)[0]
def i32(b,p): return struct.unpack_from('<i',b,p)[0]
def u16(b,p): return struct.unpack_from('<H',b,p)[0]

def root(b): return u32(b,0)
def field_off(b,t,fid):
    vt = t - i32(b,t)
    vts = u16(b,vt)
    p = 4 + fid*2
    if p+2 > vts: return None
    o = u16(b,vt+p)
    return None if o == 0 else t+o
def f_scalar(b,t,fid,fmt):
    o = field_off(b,t,fid)
    if o is None: return None
    return struct.unpack_from('<'+fmt,b,o)[0]
def f_table(b,t,fid):
    o = field_off(b,t,fid)
    return None if o is None else o+u32(b,o)
def f_vec(b,t,fid):
    o = field_off(b,t,fid)
    if o is None: return None,0
    v = o+u32(b,o)
    return v+4, u32(b,v)
def vec_int(b,start,i,fmt='i',size=4):
    return struct.unpack_from('<'+fmt,b,start+i*size)[0]

def parse(path):
    b = open(path,'rb').read()
    m = root(b)
    sg_start, sg_n = f_vec(b,m,2)
    oc_start, oc_n = f_vec(b,m,1)
    out = {'file':path,'size':len(b),'subgraphs':sg_n,'operator_codes':[]}
    for i in range(oc_n):
        t = sg_start  # placeholder
        oct_ = (oc_start + u32(b, oc_start+i*4))
        code = f_scalar(b,oct_,0,'i')  # deprecated builtin_code
        ver  = f_scalar(b,oct_,1,'i')
        # field 3 = builtin_code (new), field 4 = custom_code
        bc = f_scalar(b,oct_,3,'i')
        out['operator_codes'].append({'builtin_code':bc,'deprecated_code':code,'version':ver})
    sg = sg_start + u32(b, sg_start)  # first subgraph table
    t_start,t_n = f_vec(b,sg,0)
    in_start,in_n = f_vec(b,sg,1)
    out_start,out_n = f_vec(b,sg,2)
    op_start,op_n = f_vec(b,sg,3)
    tensors=[]
    for i in range(t_n):
        tt = t_start + u32(b,t_start+i*4)
        sh_start,sh_n = f_vec(b,tt,0)
        shape=[vec_int(b,sh_start,k) for k in range(sh_n)]
        typ = f_scalar(b,tt,1,'b')
        name_p,name_n = f_vec(b,tt,3)
        name = b[name_p:name_p+name_n].decode('utf-8','ignore') if name_n else ''
        quant = f_table(b,tt,4)
        q={'scale':None,'zero_point':None}
        if quant is not None:
            s_start,s_n = f_vec(b,quant,2)
            if s_n: q['scale']=[struct.unpack_from('<f',b,s_start+4*k)[0] for k in range(s_n)]
            z_start,z_n = f_vec(b,quant,3)
            if z_n: q['zero_point']=[struct.unpack_from('<q',b,z_start+8*k)[0] for k in range(z_n)]
        tensors.append({'idx':i,'name':name,'type':FT.get(typ,typ),'shape':shape,'quant':q})
    ins=[vec_int(b,in_start,k) for k in range(in_n)]
    outs=[vec_int(b,out_start,k) for k in range(out_n)]
    ops=[]
    for k in range(op_n):
        ot = op_start + u32(b,op_start+k*4)
        opcode = f_scalar(b,ot,0,'i')
        ops.append({'opcode_index':opcode})
    out['inputs']=[tensors[i] for i in ins]
    out['outputs']=[tensors[i] for i in outs]
    out['tensors']=tensors
    out['ops']=ops
    return out

if __name__=='__main__':
    for p in sys.argv[1:]:
        r=parse(p)
        print('='*70); print(p); print('size',r['size'])
        print('operator_codes:', r['operator_codes'])
        print('ops count:', len(r['ops']), 'opcodes used:', sorted(set(o['opcode_index'] for o in r['ops'])))
        print('--- inputs ---')
        for t in r['inputs']: print(json.dumps(t,ensure_ascii=False))
        print('--- outputs ---')
        for t in r['outputs']: print(json.dumps(t,ensure_ascii=False))
        print('--- tensors with data (first 10 by size) ---')
        print('total tensors', len(r['tensors']))
