#!/usr/bin/env python3
"""Reproduce exact Nick draw-wrapper certificates from a user-supplied JAR.

Read-only, no JAR distributed. This audits code identity and narrow wrapper
shape, not the loaded linkage, Canvas scope or gameplay.
"""
import argparse
import hashlib
from pathlib import Path
from zipfile import ZipFile
from ninja_render_island_audit import methods

SHA='11b1d4c11f9082b9d07bc7bd92a9ad3abad40764853e23686cc86686869c966c'
IMAGE=b'Ljavax/microedition/lcdui/Image;'
GRAPHICS=b'javax/microedition/lcdui/Graphics'
REGION=b'('+IMAGE+b'IIIIIIII)V'
DRAW_IMAGE=b'('+IMAGE+b'III)V'
RECT=b'(IIII)V'
ROUND=b'(IIIIII)V'
CERTS=[
    (b'a',REGION,b'drawRegion',10,67,3,46,64,'13ca49de9427be04ffe4b4e0e3a96af00e0d16562093f8936a1ca118f3a87fa1'),
    (b'a',DRAW_IMAGE,b'drawImage',5,25,2,14,22,'1ee77500c072c094c3874f28ef0fc4480ad9ac0ca2ce1e6b528e2171770964cc'),
    (b'b',RECT,b'drawRect',5,39,2,28,36,'73b1c9bef76d1b44577535265ef2e106c98cb39ab0b9827c0e498d9df5734091'),
    (b'c',RECT,b'fillRect',5,39,2,28,36,'f970365c2b2f1ab0245b63ff3e12fce6d48d70b38613be9c21336afaf775d7a1'),
    (b'a',RECT,b'drawLine',5,39,2,28,36,'16ef1049c6b5ffe2972169d921f157dabb04885f43fad876c37cc14c3558f7e3'),
    (b'a',ROUND,b'drawRoundRect',7,59,2,44,56,'5bfaa71035f90aa97461235331adde12e7d2c0d5f2cd2da4d1cdd1691360d704'),
    (b'b',ROUND,b'fillRoundRect',7,59,2,44,56,'2b83aef0f987026cac48f77abd50b688eadf25b1d27250282c7bb8704505d01a'),
    (b'c',ROUND,b'drawArc',7,43,2,28,40,'f2747bfbb7740fe875dfb86d7aafc26a0f7517c7387bd5678d281168031fa9af'),
]

def verify(path,source):
    if hashlib.sha256(path.read_bytes()).hexdigest()!=SHA:
        raise ValueError('unsupported Nick archive')
    with ZipFile(path) as z:
        if z.namelist().count('Class_hvi.class')!=1:
            raise ValueError('ambiguous wrapper class')
        body=list(methods(z.read('Class_hvi.class')))
    for name,desc,sink,argc,length,scale,field,call,digest in CERTS:
        found=[row for row in body if row[:2]==(name,desc)]
        if len(found)!=1:raise ValueError('wrapper identity mismatch')
        _,_,code,stack,locals,handlers,syms=found[0]
        if (len(code),stack,locals,len(handlers))!=(length,argc,argc,0):
            raise ValueError('wrapper frame mismatch')
        converted=bytearray(code)
        pc=0
        while pc<len(code):
            op=code[pc]
            if op in (0xb2,0xb4,0xb6,0x11):
                v=int.from_bytes(code[pc+1:pc+3],'big')
                converted[pc+1:pc+3]=v.to_bytes(2,'little')
                if op==0xb2 and syms[v]!=(9,b'Class_hvi',b'g',b'I'):
                    raise ValueError('unexpected static read')
                if op==0xb4 and syms[v]!=(9,b'Class_hvi',b'a',b'Ljavax/microedition/lcdui/Graphics;'):
                    raise ValueError('unexpected instance read')
                if op==0xb6 and (pc+1!=call or syms[v]!=(10,GRAPHICS,sink,desc)):
                    raise ValueError('unexpected call')
                pc+=3
            elif op in (0x15,0x36,0x10):pc+=2
            elif op in (*range(0x1a,0x1e),0x2a,0x2b,*range(0x3b,0x3f),0x68,0x03,0xb1):pc+=1
            else:raise ValueError('unknown effect: '+hex(op))
        if hashlib.sha256(converted).hexdigest()!=digest or code[-1]!=0xb1:
            raise ValueError('converted wrapper digest mismatch')
        if bytes([code[scale-1],code[field-1],code[call-1]])!=b'\xb2\xb4\xb6':
            raise ValueError('operand offset mismatch')
        encoded=','.join('0x'+digest[i:i+2] for i in range(0,64,2))
        if encoded not in source:raise ValueError('runtime certificate missing')
        print(name.decode(),desc.decode(),sink.decode(),argc,digest)
    print('8 exact Nick draw wrapper certificates PASS; runtime_authorized=False')
if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('archive',type=Path)
    p.add_argument('--source',type=Path,default=Path(__file__).resolve().parents[1]/'J2MEEmulator/minijvm/jvm/interpreter.c')
    a=p.parse_args()
    verify(a.archive,a.source.read_text())
