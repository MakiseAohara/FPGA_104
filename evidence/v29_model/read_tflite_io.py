# -*- coding: utf-8 -*-
"""读取 tflite 输入/输出张量的类型、shape、量化参数（纯标准库，已按 flatbuffers 语义修正）"""
import struct, sys, json

FT = {0:'FLOAT32',1:'FLOAT16',2:'INT32',3:'UINT8',4:'INT64',5:'STRING',6:'BOOL',
      7:'INT16',8:'COMPLEX64',9:'INT8',10:'FLOAT64',11:'COMPLEX128',12:'UINT64',
      13:'RESOURCE',14:'VARIANT',15:'UINT32',16:'UINT16'}

def u32(b,p): return struct.unpack_from('<I',b,p)[0]
def i32(b,p): return struct.unpack_from('<i',b,p)[0]
def u16(b,p): return struct.unpack_from('<H',b,p)[0]

def vtable(b,t): return t - i32(b,t)
def field(b,t,fid):
    vt=vtable(b,t); vts=u16(b,vt); p=4+fid*2
    if p+2>vts: return None
    o=u16(b,vt+p)
    return None if o==0 else t+o
def scalar(b,t,fid,fmt):
    o=field(b,t,fid); return None if o is None else struct.unpack_from('<'+fmt,b,o)[0]
def table_field(b,t,fid):
    o=field(b,t,fid); return None if o is None else o+u32(b,o)
def vector(b,t,fid):
    o=field(b,t,fid)
    if o is None: return None,0
    v=o+u32(b,o); return v,u32(b,v)
def table_at(b,vec,i):
    e=vec+4+i*4; return e+u32(b,e)

def parse(path):
    b=open(path,'rb').read()
    m=u32(b,0)
    svec,sn=vector(b,m,2)
    sg=table_at(b,svec,0)
    tvec,tn=vector(b,sg,0)
    ivec_,inn=vector(b,sg,1)
    ovec,on=vector(b,sg,2)
    tensors=[]
    for i in range(tn):
        tt=table_at(b,tvec,i)
        shv,shn=vector(b,tt,0)
        shape=[i32(b,shv+4+k*4) for k in range(shn)]
        typ=scalar(b,tt,1,'b')
        np_,nn=vector(b,tt,3)
        name=b[np_:np_+nn].decode('utf-8','ignore') if nn else ''
        q=table_field(b,tt,4)
        scale=zp=None
        if q is not None:
            sv,sn2=vector(b,q,2)
            if sn2: scale=[struct.unpack_from('<f',b,sv+4+4*k)[0] for k in range(sn2)]
            zv,zn=vector(b,q,3)
            if zn: zp=[struct.unpack_from('<q',b,zv+4+8*k)[0] for k in range(zn)]
        tensors.append({'idx':i,'name':name,'type':FT.get(typ,typ),'shape':shape,'scale':scale,'zero_point':zp})
    ins=[i32(b,ivec_+4+k*4) for k in range(inn)]
    outs=[i32(b,ovec+4+k*4) for k in range(on)]
    return {'size':len(b),'n_tensors':tn,'inputs':[tensors[i] for i in ins],
            'outputs':[tensors[i] for i in outs],'tensors':tensors}

if __name__=='__main__':
    for p in sys.argv[1:]:
        r=parse(p)
        print('='*70); print(p,'size',r['size'],'tensors',r['n_tensors'])
        print('INPUT :',json.dumps(r['inputs'],ensure_ascii=False))
        print('OUTPUT:',json.dumps(r['outputs'],ensure_ascii=False))
        for t in r['tensors'][:12]:
            print('  t%-3d %-10s %-16s scale=%s zp=%s %s' % (t['idx'],t['type'],str(t['shape']),t['scale'],t['zero_point'],t['name'][:30]))
