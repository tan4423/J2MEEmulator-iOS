#!/usr/bin/env python3
"""Read-only exact Nick k1 effect projection oracle. No runtime authorization.

Copies only k1/q3/m3 Code and required fields into a temporary JVM fixture.
Original game JAR is never rewritten or distributed. Native projection is
compared against original ordered putstatic writes and fault outcomes.
"""
import argparse
import ctypes as C
import hashlib
import json
from pathlib import Path
import random
import struct
import subprocess
import tempfile
import zipfile
from ninja_render_island_audit import methods

SHA='11b1d4c11f9082b9d07bc7bd92a9ad3abad40764853e23686cc86686869c966c'
OWNER=b'Class_hii'; DESC=b'(LClass_hvi;)V'
SCRATCH={b'a2',b'b2',b'c2',b'd2'}
LENGTH={i:1 for i in range(202)}
for op in [16,18,*range(21,26),*range(54,59),169,188]:LENGTH[op]=2
for op in [17,19,20,132,*range(153,169),*range(178,185),187,189,192,193,198,199]:LENGTH[op]=3
for op in [185,186,200,201]:LENGTH[op]=5
LENGTH[197]=4

def decode(code):
    pc=0
    while pc<len(code):
        op=code[pc];n=LENGTH[op]
        if op in (170,171):
            a=(pc+4)&~3
            def i32(p):return int.from_bytes(code[p:p+4],'big',signed=True)
            n=a-pc+(12+4*(i32(a+8)-i32(a+4)+1) if op==170 else 8+8*i32(a+4))
        if op==196:n=6 if code[pc+1]==132 else 4
        if n<=0 or pc+n>len(code):raise ValueError('bad instruction length')
        yield pc,op,int.from_bytes(code[pc+1:pc+3],'big') if n>=3 else 0
        pc+=n

def fixture(data):
    """Keep original CP and original Code attributes, widen fixture fields only."""
    u2=lambda p:struct.unpack_from('>H',data,p)[0]
    u4=lambda p:struct.unpack_from('>I',data,p)[0]
    n=u2(8);p=10;cp={};i=1
    while i<n:
        tag=data[p];p+=1
        if tag==1:
            k=u2(p);p+=2;cp[i]=data[p:p+k];p+=k
        elif tag in (3,4,9,10,11,12,17,18):p+=4
        elif tag in (5,6):p+=8;i+=1
        elif tag in (7,8,16,19,20):p+=2
        elif tag==15:p+=3
        else:raise ValueError('constant tag')
        i+=1
    p+=6;p+=2+2*u2(p);head=data[:p]
    wanted_fields={(b'a2',b'I'),(b'b2',b'I'),(b'c2',b'I'),(b'd2',b'I'),(b'j1',b'I'),(b'r3',b'I'),(b'd4',b'B'),(b'u3',b'[C'),(b'x3',b'[I')}
    wanted_fields|={(n,b'Ljavax/microedition/lcdui/Image;') for n in (b't1',b'v1',b'w1')}
    def members(p,wanted):
        count=u2(p);p+=2;out=[];found=set()
        for _ in range(count):
            start=p;flags=u2(p);key=(cp[u2(p+2)],cp[u2(p+4)]);ac=u2(p+6);p+=8
            for __ in range(ac):p+=6+u4(p+2)
            if key in wanted:
                if not flags&8 or flags&(0x20|0x40|0x100|0x400):raise ValueError('bad member flags')
                out.append(struct.pack('>H',(flags&~7)|1)+data[start+2:p]);found.add(key)
        if found!=wanted:raise ValueError('missing fixture member')
        return p,struct.pack('>H',len(out))+b''.join(out)
    p,f=members(p,wanted_fields);p,m=members(p,{(b'k1',DESC),(b'q3',b'(II)I'),(b'm3',b'(II)I')})
    return head+f+m+b'\0\0'


def audit(z):
    entries=[p for p in z.namelist() if p.endswith('.class')]
    if len(set(entries))!=len(entries):raise ValueError('duplicate class')
    refs=[];summary={};effect_methods=[];native_reflect=[];count=0
    for path in entries:
        owner=path[:-6].encode()
        for name,desc,code,stack,locals,handlers,syms in methods(z.read(path)):
            count+=1;ops=list(decode(code));calls=[];writes=[]
            for pc,op,ix in ops:
                if op in (178,179,180,181):
                    sym=syms[ix]
                    if sym[1]==OWNER and sym[2] in SCRATCH and sym[3]==b'I':
                        refs.append((owner.decode(),name.decode(),desc.decode(),pc,op,sym[2].decode()))
                if op in (182,183,184,185):
                    sym=syms[ix];calls.append((pc,sym))
                    if sym[1].startswith(b'java/lang/reflect') or sym[2] in (b'getDeclaredField',b'getField',b'getDeclaredFields',b'getFields'):
                        native_reflect.append((owner.decode(),name.decode(),pc))
                if op in (179,181,*range(79,87),194,195):writes.append(pc)
            if (owner,name,desc) in [(OWNER,b'k1',DESC),(b'Class_hac',b'a0',DESC),(b'Class_hda',b'a0',DESC),(b'Class_hhb',b'a',DESC)]:
                key=(owner+b'.'+name).decode()
                summary[key]={'instructions':len(ops),'writes_or_monitors':writes,'calls':len(calls),'handlers':len(handlers)}
            if owner==b'Class_hmi' and name in (b'm',b'k',b'n',b'p',b'o',b'j',b'l',b'h'):
                effect_methods.append((name.decode(),desc.decode(),[(pc,(s[1]+b'.'+s[2]+s[3]).decode()) for pc,s in calls if s[1].startswith(b'Class_')]))
    expected=[(1171,179,'a2'),(1178,179,'b2'),(1186,178,'b2'),(1195,179,'d2'),(1202,179,'c2'),(1220,178,'c2')]
    if any(r[:3]!=('Class_hii','k1',DESC.decode()) for r in refs) or sorted(r[3:] for r in refs)!=expected:
        raise ValueError('scratch escaped exact method')
    if native_reflect:raise ValueError('reflection needs review')
    return {'archive_methods_with_code':count,'scratch_accesses':refs,'focus':summary,'built_in_graphics_policy_routes':effect_methods,'reflection_field_calls':native_reflect,'runtime_authorized':False}

ASM=r'''import java.nio.file.*;import jdk.internal.org.objectweb.asm.*;
public class Mark {
 public static void main(String[] a)throws Exception {
  Path path=Path.of(a[0]);ClassReader r=new ClassReader(Files.readAllBytes(path));ClassWriter w=new ClassWriter(r,ClassWriter.COMPUTE_MAXS);
  r.accept(new ClassVisitor(Opcodes.ASM8,w){
   public MethodVisitor visitMethod(int access,String name,String desc,String sig,String[] ex){
    MethodVisitor mv=super.visitMethod(access,name,desc,sig,ex);
    if(!name.equals("k1")||!desc.equals("(LClass_hvi;)V"))return mv;
    return new MethodVisitor(Opcodes.ASM8,mv){
     public void visitFieldInsn(int op,String owner,String name,String desc){
      if(op==Opcodes.PUTSTATIC&&owner.equals("Class_hii")&&desc.equals("I")){
       int id=switch(name){case "a2"->0;case "b2"->1;case "d2"->2;case "c2"->3;default->throw new AssertionError(name);};
       super.visitInsn(Opcodes.DUP);super.visitLdcInsn(id);super.visitMethodInsn(Opcodes.INVOKESTATIC,"Trace","write","(II)V",false);
      }
      super.visitFieldInsn(op,owner,name,desc);
     }
    };}
  },0);Files.write(path,w.toByteArray());
 }
}'''
HARNESS=r'''import java.io.*;
public final class RunMap {
 static int[] arr(String s){if(s.equals("-"))return null;if(s.equals("_"))return new int[0];String[] p=s.split(",");int[] a=new int[p.length];for(int i=0;i<a.length;i++)a[i]=Integer.parseInt(p[i]);return a;}
 public static void main(String[] args)throws Exception{
  Class_hvi w=new Class_hvi();BufferedReader r=new BufferedReader(new FileReader(args[0]));String line;
  while((line=r.readLine())!=null){String[] p=line.split("\t");int[] v=arr(p[0]);int[] tiles=arr(p[1]);
   Class_hac.r24=v[0];Class_hac.y26=v[1];Class_hac.v25=v[2];Class_hac.b28=v[3];Class_hii.j1=v[4];Class_hii.r3=v[5];Class_hii.d4=(byte)v[6];Class_hac.b20=v[7];Class_hac.e10=v[8];
   Class_hii.a2=v[9];Class_hii.b2=v[10];Class_hii.c2=v[11];Class_hii.d2=v[12];
   Class_hii.u3=tiles==null?null:new char[tiles.length];if(tiles!=null)for(int i=0;i<tiles.length;i++)Class_hii.u3[i]=(char)tiles[i];Class_hii.x3=arr(p[2]);
   Trace.writes=0;Trace.hash=0;int fault=0;
   try{Class_hii.k1(w);}catch(NullPointerException e){fault=1;}catch(ArrayIndexOutOfBoundsException e){fault=2;}catch(ArithmeticException e){fault=3;}
   System.out.println(fault+","+Class_hii.a2+","+Class_hii.b2+","+Class_hii.c2+","+Class_hii.d2+","+Trace.writes+","+Long.toUnsignedString(Trace.hash));
  }
 }
}'''
TRACE='''public final class Trace { static long writes,hash;public static void write(int v,int field){writes++;hash=(hash*1099511628211L)^((long)field<<32)^(v&0xffffffffL);} }'''
class Input(C.Structure):
    _fields_=[(n,C.c_int32) for n in ('x0','x1','y0','y1','stride','kind','scale','camera_x','center')]+[('tiles',C.POINTER(C.c_uint16)),('tile_count',C.c_size_t),('flags',C.POINTER(C.c_int32)),('flag_count',C.c_size_t)]
class Result(C.Structure):
    _fields_=[(n,C.c_int32) for n in ('a','b','c','d')]+[('writes',C.c_uint64),('trace',C.c_uint64)]

def cases(n):
    rng=random.Random(77123)
    def i32():return rng.randint(-2147483648,2147483647)
    special=[0,1,6,13,14,16,19,20,21,22,23,24,25,26,35,36,45,46,52,53,56,134,65535]
    for i in range(n):
        w=rng.randint(1,9);h=rng.randint(1,9);kind=i%7;scale=rng.choice([24,24,24,0,-1,1,-128,127]);
        x0=0 if i%4 else -1;y0=0 if i%3 else 2;x1=w+(i%13==0);y1=h+(i%17==0)
        if i%11==0:x1=x0
        if i%19==0:y1=y0
        if i%29==0:x0=2147483646;x1=2147483647
        stride=w if i%31 else rng.choice([0,-1,2147483647]);
        v=[x0,x1,y0,y1,stride,kind,scale,i32(),i32(),i32(),i32(),i32(),i32()]
        t=[rng.choice(special) if i%2 else rng.randrange(160) for _ in range(w*h)]
        f=[rng.randrange(8192) if i%5 else rng.choice([0,16,32,64,128,2048,4096,16|64]) for _ in t]
        if i%37==0:t=None
        if i%41==0:f=None
        if i%43==0 and t is not None:t=t[:len(t)//2]
        if i%47==0 and f is not None:f=f[:len(f)//2]
        yield v,t,f

def encode(a):return '-' if a is None else ','.join(map(str,a)) if a else '_'

def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('archive',type=Path);p.add_argument('--header',type=Path,default=Path(__file__).resolve().parents[1]/'J2MEEmulator/minijvm/jvm/jarbox_nick_map_effect.h');p.add_argument('--trials',type=int,default=12000);a=p.parse_args()
    if not 1000<=a.trials<=100000:raise ValueError('trial bound')
    if hashlib.sha256(a.archive.read_bytes()).hexdigest()!=SHA:raise ValueError('unsupported archive')
    with tempfile.TemporaryDirectory() as td,zipfile.ZipFile(a.archive) as z:
        root=Path(td);report=audit(z);(root/'Class_hii.class').write_bytes(fixture(z.read('Class_hii.class')))
        pkg=root/'javax/microedition/lcdui';pkg.mkdir(parents=True);(pkg/'Image.java').write_text('package javax.microedition.lcdui; public class Image {}')
        (root/'Class_hvi.java').write_text('public final class Class_hvi { public void a(javax.microedition.lcdui.Image i,int a,int b,int c,int d,int e,int f,int g,int h){} }')
        (root/'Class_hac.java').write_text('public class Class_hac {public static int r24,y26,v25,b28,b20,e10;}');(root/'Class_hxb.java').write_text('public class Class_hxb {public static int s5;}')
        (root/'Trace.java').write_text(TRACE);(root/'RunMap.java').write_text(HARNESS);(root/'Mark.java').write_text(ASM)
        subprocess.run(['javac','--release','8','-cp',str(root),'-d',str(root),*map(str,[pkg/'Image.java',root/'Class_hvi.java',root/'Class_hac.java',root/'Class_hxb.java',root/'Trace.java',root/'RunMap.java'])],check=True,timeout=30)
        export='java.base/jdk.internal.org.objectweb.asm=ALL-UNNAMED'
        subprocess.run(['javac','--add-exports',export,str(root/'Mark.java')],check=True,timeout=30)
        subprocess.run(['java','--add-exports',export,'-cp',str(root),'Mark',str(root/'Class_hii.class')],check=True,timeout=30)
        (root/'bridge.c').write_text('#include "jarbox_nick_map_effect.h"\nint project(const JnmInput *in,const JnmResult *initial,JnmResult *out){return jnm_project(in,initial,out);}\n')
        subprocess.run(['cc','-std=c11','-O2','-Wall','-Wextra','-Werror','-shared','-fPIC','-I',str(a.header.resolve().parent),str(root/'bridge.c'),'-o',str(root/'bridge.so')],check=True,timeout=30)
        project=C.CDLL(str(root/'bridge.so')).project;project.argtypes=[C.POINTER(Input),C.POINTER(Result),C.POINTER(Result)];project.restype=C.c_int
        scenarios=list(cases(a.trials));(root/'input.tsv').write_text(''.join('\t'.join(encode(x) for x in row)+'\n' for row in scenarios))
        lines=subprocess.check_output(['java','-Xint','-Xverify:all','-cp',str(root),'RunMap',str(root/'input.tsv')],text=True,timeout=90).splitlines()
        if len(lines)!=len(scenarios):raise ValueError('oracle length')
        accepted=refused=faults=matched_writes=nonempty=0
        for i,((v,t,f),line) in enumerate(zip(scenarios,lines)):
            ct=None if t is None else (C.c_uint16*len(t))(*t);cf=None if f is None else (C.c_int32*len(f))(*f)
            inp=Input(*v[:9],ct,len(t or ()),cf,len(f or ()));initial=Result(*v[9:],0,0);out=Result(1,2,3,4,5,6)
            expected=list(map(int,line.split(',')));faults+=bool(expected[0]);ok=project(C.byref(inp),C.byref(initial),C.byref(out))
            actual=[out.a,out.b,out.c,out.d,out.writes,out.trace]
            if ok:
                if expected[0] or expected[1:]!=actual:raise AssertionError((i,v,expected,actual))
                accepted+=1;matched_writes+=out.writes;nonempty+=bool(out.writes)
            else:
                if actual!=[1,2,3,4,5,6]:raise AssertionError('refusal modified state')
                refused+=1
        if min(accepted,refused,faults,nonempty)<100 or matched_writes<1000:raise ValueError('vacuous oracle')
        report.update(accepted=accepted,refused=refused,original_faults=faults,matched_write_events=matched_writes,accepted_with_writes=nonempty)
        print(json.dumps(report,indent=2))
if __name__=='__main__':main()
