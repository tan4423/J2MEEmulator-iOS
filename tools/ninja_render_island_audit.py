#!/usr/bin/env python3
"""Read-only structural render-island coverage; never grants admission."""
import ctypes as C
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import zipfile

CORE=Path(os.environ.get('JARBOX_CORE', Path(__file__).resolve().parents[1]/'J2MEEmulator/minijvm/jvm'))
KNOWN={'11b1d4c11f9082b9d07bc7bd92a9ad3abad40764853e23686cc86686869c966c':('Nick','Class_hvi','abc'),
       '1e79927643228d369c1f590879bdefe2051820080606dd433db7da349028b9f9':('Nick','Class_hvi','abc'),
       '3420df8cb91bcc33852230d1c6f9166a99d6ce3f2c4a332cf1bad851c3f7b276':('Trung','Class_gp','abc'),
       'c48f8e40e8c619a8503626b14940693d3fd37f1ecbba1c1342f53957d42f0080':('V9','eg','efg'),
       '96f811dc1317ec41ba01953350436dc8f850090c3018a26b4ae35f3124c2e95d':('Original','t','abc')}
WRAPPER=r'''
#include <stdint.h>
typedef struct {union{int64_t lvalue;uint64_t ulvalue;int32_t ivalue;uint32_t uivalue;};void *rvalue;} StackEntry;
#include "jarbox_render_island.h"
void audit(const uint8_t *c,unsigned n,unsigned l,unsigned s,const JbiHandler *h,unsigned nh,JriCP cp,unsigned *out){
    JriPlan *p=jri_build(c,n,l,s,h,nh,1,cp,NULL);if(!p)return;
    out[0]=p->count;
    for(unsigned i=0;i<p->count;i++){out[1]+=p->island[i].steps;out[2]+=p->island[i].nreads;}
    free(p);
}
'''
class H(C.Structure):
    _fields_=[('start',C.c_uint16),('end',C.c_uint16),('handler',C.c_uint16)]
CP=C.CFUNCTYPE(C.c_uint,C.c_void_p,C.c_uint,C.c_uint)

def methods(data):
    pos=0
    def take(n):
        nonlocal pos
        b=data[pos:pos+n];pos+=n
        if len(b)!=n:raise ValueError('short class')
        return b
    def u(n):return int.from_bytes(take(n),'big')
    if take(4)!=b'\xca\xfe\xba\xbe':raise ValueError('class magic')
    take(4);pool={};i=1;nc=u(2)
    while i<nc:
        t=u(1)
        if t==1:pool[i]=(t,take(u(2)))
        elif t in (7,8,16,19,20):pool[i]=(t,u(2))
        elif t in (9,10,11,12,17,18):pool[i]=(t,u(2),u(2))
        elif t in (3,4):take(4)
        elif t in (5,6):take(8);i+=1
        elif t==15:take(3)
        else:raise ValueError('constant tag '+str(t))
        i+=1
    def string(ix):return pool[ix][1]
    def symbol(ix):
        t,owner,nt=pool[ix];_,name,desc=pool[nt]
        return t,string(pool[owner][1]),string(name),string(desc)
    syms={ix:symbol(ix) for ix,v in pool.items() if v[0] in (9,10,11)}
    take(6);take(2*u(2))
    for _ in range(u(2)):
        take(6)
        for __ in range(u(2)):take(2);take(u(4))
    for _ in range(u(2)):
        take(2);name=string(u(2));desc=string(u(2))
        for __ in range(u(2)):
            attr=string(u(2));n=u(4);end=pos+n
            if end>len(data):raise ValueError('short attribute')
            if attr==b'Code':
                stack,locals=u(2),u(2);code=take(u(4));hs=[]
                for ___ in range(u(2)):hs.append(H(u(2),u(2),u(2)));u(2)
                if pos>end:raise ValueError('invalid Code')
                yield name,desc,code,stack,locals,hs,syms
            pos=end

def scan(path,audit):
    sha=hashlib.sha256(path.read_bytes()).hexdigest();family,wrapper,rects=KNOWN[sha]
    counts=[0,0,0,0];focus=[]
    with zipfile.ZipFile(path) as z:
        entries=[n for n in z.namelist() if n.endswith('.class')]
        if len(entries)!=len(set(entries)):raise ValueError('duplicate class')
        for owner in sorted(entries):
            for name,desc,code,stack,locals,hs,syms in methods(z.read(owner)):
                @CP
                def classify(_,op,ix):
                    t,cl,m,d=syms.get(ix,(0,b'',b'',b''))
                    if op==0xb2 and t==9:
                        return 1 if d in (b'I',b'B',b'C',b'S',b'Z') else 2 if d.startswith((b'L',b'[')) else 0
                    if op!=0xb6 or t!=10 or cl!=wrapper.encode():return 0
                    if m==b'a' and d==b'(Ljavax/microedition/lcdui/Image;III)V':return 5|(3<<4)
                    if m==b'a' and d==b'(Ljavax/microedition/lcdui/Image;IIIIIIII)V':return 10|(3<<4)
                    if m in [bytes([x]) for x in rects.encode()] and d==b'(IIII)V':return 5|(1<<4)
                    return 0
                out=(C.c_uint*3)()
                audit(code,len(code),locals,stack,(H*len(hs))(*hs),len(hs),classify,out)
                if out[0]:
                    counts[0]+=1
                    for i in range(3):counts[i+1]+=out[i]
                    if family=='Nick' and owner in ('Class_hda.class','Class_hac.class','Class_hui.class','Class_hii.class','Class_hxb.class'):
                        focus.append([owner,name.decode(),desc.decode(),*out])
    return dict(family=family,sha256=sha,methods=counts[0],islands=counts[1],operations=counts[2],static_read_obligations=counts[3],focus=focus,runtime_authorized=False)

def main():
    with tempfile.TemporaryDirectory() as d:
        p=Path(d);src=p/'audit.c';lib=p/'audit.so';src.write_text(WRAPPER)
        subprocess.run([os.environ.get('CC','cc'),'-shared','-fPIC','-O2','-std=c11','-Wall','-Wextra','-Werror','-I',str(CORE),str(src),'-o',str(lib)],check=True,timeout=30)
        audit=C.CDLL(str(lib)).audit
        audit.argtypes=[C.c_char_p,C.c_uint,C.c_uint,C.c_uint,C.POINTER(H),C.c_uint,CP,C.POINTER(C.c_uint)];audit.restype=None
        print(json.dumps([scan(Path(f),audit) for f in sys.argv[1:]],indent=2))
if __name__=='__main__':main()
