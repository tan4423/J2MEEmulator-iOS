#!/usr/bin/env python3
"""Read-only coverage of the actual C block compiler on exact Ninja archives."""
import argparse
import ctypes as C
import json
import os
from pathlib import Path
import subprocess
import tempfile
import zipfile
from ninja_headless_corpus import identify, digest

JVM = Path(__file__).resolve().parents[1] / 'J2MEEmulator/minijvm/jvm'
WRAPPER = r'''
#include <stdint.h>
typedef struct {union{int64_t lvalue;uint64_t ulvalue;int32_t ivalue;uint32_t uivalue;};void *rvalue;} StackEntry;
#include "jarbox_block_ir.h"
unsigned audit(const uint8_t *c,unsigned n,unsigned locals,unsigned stack,const JbiHandler *h,unsigned nh,unsigned *out) {
    JbiPlan *p=jbi_build(c,n,locals,stack,h,nh,1);if(!p)return 0;
    out[0]=p->spans;out[1]=p->ops;out[2]=p->bytes;free(p);return 1;
}
'''

class H(C.Structure):
    _fields_=[('start',C.c_uint16),('end',C.c_uint16),('handler',C.c_uint16)]


def methods(data):
    pos=0
    def take(n):
        nonlocal pos
        a=data[pos:pos+n];pos+=n
        if len(a)!=n: raise ValueError('short class')
        return a
    def u(n): return int.from_bytes(take(n),'big')
    if take(4)!=b'\xca\xfe\xba\xbe': raise ValueError('class magic')
    take(4);cp={};i=1;nc=u(2)
    while i<nc:
        t=u(1)
        if t==1:cp[i]=take(u(2))
        elif t in (3,4,9,10,11,12,17,18):take(4)
        elif t in (5,6):take(8);i+=1
        elif t in (7,8,16,19,20):take(2)
        elif t==15:take(3)
        else:raise ValueError('constant tag '+str(t))
        i+=1
    take(6);take(2*u(2))
    for _ in range(u(2)):
        take(6)
        for __ in range(u(2)):take(2);take(u(4))
    for _ in range(u(2)):
        take(2);name=cp[u(2)];desc=cp[u(2)]
        for __ in range(u(2)):
            attr=cp[u(2)];n=u(4);end=pos+n
            if end>len(data):raise ValueError('short attribute')
            if attr==b'Code':
                stack,locals=u(2),u(2);code=take(u(4));hs=[]
                for ___ in range(u(2)):hs.append(H(u(2),u(2),u(2)));u(2)
                if pos>end:raise ValueError('invalid Code attribute')
                yield name,desc,code,stack,locals,hs
            pos=end


def scan(path, audit):
    sha=digest(path.read_bytes());family,_=identify(sha)
    total=covered=spans=ops=mem=0
    important=[]
    with zipfile.ZipFile(path) as z:
        entries=[n for n in z.namelist() if n.endswith('.class')]
        if len(entries)!=len(set(entries)):raise ValueError('duplicate class')
        for name in sorted(entries):
            for method,desc,code,stack,locals,hs in methods(z.read(name)):
                total+=1;out=(C.c_uint*3)()
                if audit(code,len(code),locals,stack,(H*len(hs))(*hs),len(hs),out):
                    covered+=1;spans+=out[0];ops+=out[1];mem+=out[2]
                    if name in ('Class_hda.class','Class_hpa.class','Class_hac.class','Class_hxb.class','Class_hf.class','Class_hui.class'):
                        important.append(dict(owner=name[:-6],method=method.decode(),descriptor=desc.decode(),spans=out[0],ops=out[1]))
    return dict(family=family,archive_sha256=sha,code_methods=total,methods_with_spans=covered,
                spans=spans,lowered_operations=ops,plan_bytes_if_all_published=mem,
                selected_nick_methods=important,runtime_authorized=False)


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('archives',nargs='+',type=Path)
    args=p.parse_args()
    with tempfile.TemporaryDirectory() as d:
        root=Path(d);src=root/'audit.c';lib=root/'audit.so'
        src.write_text(WRAPPER)
        subprocess.run([os.environ.get('CC','cc'),'-shared','-fPIC','-O2','-std=c11',
                        '-Wall','-Wextra','-Werror','-I',str(JVM),str(src),'-o',str(lib)],check=True,timeout=30)
        audit=C.CDLL(str(lib)).audit
        audit.argtypes=[C.c_char_p,C.c_uint,C.c_uint,C.c_uint,C.POINTER(H),C.c_uint,C.POINTER(C.c_uint)]
        audit.restype=C.c_uint
        print(json.dumps([scan(path,audit) for path in args.archives],indent=2,sort_keys=True))

if __name__=='__main__':
    main()
