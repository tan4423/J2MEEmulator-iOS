#!/usr/bin/env python3
"""Compile one real map loop to an effect-only Java oracle (never runtime admission).

Requires a trusted local Nick t5 archive and JDK. Copies only selected method
Code attributes to a temporary test class, without modifying the input JAR.
The screen sink and external static fields are controlled test doubles.
"""
import argparse
from collections import deque
from dataclasses import dataclass
import hashlib
import json
from pathlib import Path
import re
import struct
import subprocess
import tempfile
import zipfile

OWNER='Class_hii'
DESC='(LClass_hvi;)V'
DRAW='Class_hvi.a:(Ljavax/microedition/lcdui/Image;IIIIIIII)V'
SHA='11b1d4c11f9082b9d07bc7bd92a9ad3abad40764853e23686cc86686869c966c'
WRITE_FIELDS={'a2','b2','c2','d2'}

@dataclass
class Op:
    pc:int
    code:str
    uses:set
    defs:set
    successors:tuple
    effect:bool=False
    branch:bool=False


def disassemble(jar):
    s=subprocess.check_output(['javap','-classpath',str(jar),'-p','-s','-c',OWNER],text=True,timeout=30)
    body=s.split('public static final void k1(Class_hvi);',1)[1].split('\n  public ',1)[0]
    if 'descriptor: '+DESC not in body or 'Exception table:' in body:
        raise ValueError('method shape')
    return [(int(m[1]),m[2],m[3]) for line in body.splitlines() if (m:=re.match(r'^\s+(\d+):\s+(\w+)\s*(.*)$',line))]


def lower(ins):
    """Typed stack-to-slot CFG. Only accepted observed operations; fail closed."""
    todo=deque([(ins[0][0],())]);seen={};ops={};fields=set();writes=[];pcs=[i[0] for i in ins]
    table={pc:(op,arg,pcs[i+1] if i+1<len(pcs) else None) for i,(pc,op,arg) in enumerate(ins)}
    while todo:
        pc,incoming=todo.popleft()
        if pc in seen:
            if seen[pc]!=incoming:raise ValueError('stack merge')
            continue
        seen[pc]=incoming;stack=list(incoming);op,arg,nxt=table[pc];uses=set();defs=set();effect=branch=False
        successors=(nxt,)
        def pop(t):
            if not stack or stack[-1]!=t:raise ValueError('stack type at '+str(pc))
            stack.pop();v=('s' if t=='I' else 'r')+str(len(stack));uses.add(v);return v
        def push(t,expr):
            v=('s' if t=='I' else 'r')+str(len(stack));stack.append(t);defs.add(v);return v+'='+expr+';'
        if op.startswith('iconst_') or op in ('bipush','sipush'):
            v=(-1 if op=='iconst_m1' else int(op[-1])) if op.startswith('iconst_') else int(arg.split()[0]);code=push('I',str(v))
        elif re.fullmatch(r'iload_[123]',op):
            v='l'+op[-1];uses.add(v);code=push('I',v)
        elif re.fullmatch(r'istore_[123]',op):
            v='l'+op[-1];defs.add(v);code=v+'='+pop('I')+';'
        elif op=='aload_0':code=push('R','receiver')
        elif op=='iinc':
            l,v=map(int,arg.split(','));name='l'+str(l);uses.add(name);defs.add(name);code=f'{name}+={v};'
        elif op=='dup':
            if not stack or stack[-1]!='I':raise ValueError('dup type')
            v='s'+str(len(stack)-1);uses.add(v);code=push('I',v)
        elif op in ('getstatic','putstatic'):
            ref=arg.split('// Field ',1)[1];name,t=ref.rsplit(':',1)
            if '.' not in name:name=OWNER+'.'+name
            if not re.fullmatch(r'Class_h(?:ii|ac|xb)\.\w+',name) or t not in ('I','B','[C','Ljavax/microedition/lcdui/Image;'):raise ValueError('field '+ref)
            fields.add((name,t))
            if op=='getstatic':
                kind='I' if t in ('I','B') else 'R'
                code=push(kind,name)
                slot=('s' if kind=='I' else 'r')+str(len(stack)-1)
                code+=f'Trace.read({slot},"{name}");'
                effect=True # preserve every read, including linkage/init/volatile effects
            else:
                if t!='I' or name.split('.')[0]!=OWNER or name.split('.')[1] not in WRITE_FIELDS:raise ValueError('unexpected write')
                writes.append((pc,name));v=pop('I');code=f'Trace.write({v},"{name.split(".")[1]}");{name}={v};';effect=True
        elif op in ('iadd','isub','imul','iand','ishr','idiv','irem'):
            b,a=pop('I'),pop('I');sym=dict(iadd='+',isub='-',imul='*',iand='&',ishr='>>',idiv='/',irem='%')[op]
            code=push('I',a+sym+b);effect=op in ('idiv','irem')
        elif op=='caload':
            b,a=pop('I'),pop('R');code=push('I','((char[])'+a+')['+b+']');effect=True
        elif op=='invokestatic':
            ref=arg.split('// Method ',1)[1]
            if ref not in ('q3:(II)I','m3:(II)I'):raise ValueError('unknown call '+ref)
            b,a=pop('I'),pop('I');code=push('I',OWNER+'.'+ref[:2]+'('+a+','+b+')');effect=True
        elif op=='invokevirtual':
            if arg.split('// Method ',1)[1]!=DRAW:raise ValueError('unknown draw')
            for _ in range(8):pop('I')
            pop('R');pop('R');uses.clear();code='' # only in admitted no-op screen model
        elif op.startswith('if_icmp'):
            sym={'if_icmpeq':'==','if_icmpne':'!=','if_icmpge':'>='}.get(op)
            if sym is None:raise ValueError(op)
            b,a=pop('I'),pop('I');code=a+sym+b;successors=(int(arg.split()[0]),nxt);branch=True
        elif op=='goto':code='';successors=(int(arg.split()[0]),)
        elif op=='return':
            if stack:raise ValueError('nonempty return')
            code='return;';successors=();effect=True
        else:raise ValueError('unknown op '+op)
        if any(s not in table for s in successors):raise ValueError('bad target')
        ops[pc]=Op(pc,code,uses,defs,successors,effect,branch)
        todo.extend((p,tuple(stack)) for p in successors)
    if set(ops)!=set(table) or {name.split('.')[1] for _,name in writes}!=WRITE_FIELDS:raise ValueError('incomplete loop/effects')
    return ops,fields,sorted(writes)


def reduce(ops):
    """Erase dead pure definitions and branches with identical continuation.
    Observable reads/calls/faults and stores are roots. No code motion.
    """
    ops={p:Op(o.pc,o.code,set(o.uses),set(o.defs),o.successors,o.effect,o.branch) for p,o in ops.items()}
    while True:
        live={p:set() for p in ops}
        change=True
        while change:
            change=False
            for p,o in sorted(ops.items(),reverse=True):
                out=set().union(*(live[x] for x in o.successors))
                v=o.uses|(out-o.defs)
                if v!=live[p]:live[p]=v;change=True
        altered=False
        for p,o in ops.items():
            out=set().union(*(live[x] for x in o.successors))
            if o.defs and not o.effect and not (o.defs&out):
                o.code='';o.uses.clear();o.defs.clear();altered=True
        def target(p):
            seen=set()
            while not ops[p].code and len(ops[p].successors)==1 and p not in seen:
                seen.add(p);p=ops[p].successors[0]
            return p
        for o in ops.values():
            dest=tuple(target(x) for x in o.successors)
            if dest!=o.successors:o.successors=dest;altered=True
            if o.branch and dest[0]==dest[1]:
                o.code='';o.uses.clear();o.branch=False;o.successors=(dest[0],);altered=True
        if not altered:break
    entry=target(min(ops));reachable=set();todo=[entry]
    while todo:
        p=todo.pop()
        if p not in reachable:reachable.add(p);todo.extend(ops[p].successors)
    result={p:ops[p] for p in reachable}
    if {p for p,o in ops.items() if o.effect}!={p for p,o in result.items() if o.effect}:raise ValueError('lost effect')
    return entry,result


def emit(entry,ops):
    # Fuse linear runs into blocks; explicit branch targets preserve CFG.
    pred={p:0 for p in ops}
    for o in ops.values():
        for q in o.successors:pred[q]+=1
    leaders={entry}|{p for p,n in pred.items() if n!=1}|{q for o in ops.values() if o.branch for q in o.successors}
    lines=[];covered=set()
    for p in sorted(leaders):
        lines.append(f'case {p}:');q=p
        while True:
            if q in covered:raise ValueError('duplicate block')
            covered.add(q);o=ops[q]
            if o.code:lines.append('  Trace.step();')
            if o.branch:
                a,b=o.successors;lines.append(f'  pc=({o.code})?{a}:{b};break;');break
            if o.code:lines.append('  '+o.code)
            if not o.successors:break
            q=o.successors[0]
            if q in leaders:lines.append(f'  pc={q};break;');break
    if covered!=set(ops):raise ValueError('incomplete block emission')
    return 'public class Residual { static void run(Class_hvi receiver) {\n'+ \
        'int '+','.join(x+'=0' for x in ['l1','l2','l3']+['s'+str(i) for i in range(12)])+';\nObject '+','.join('r'+str(i)+'=null' for i in range(12))+';\n'+f'int pc={entry};while(true){{switch(pc){{\n'+'\n'.join(lines)+'\ndefault:throw new AssertionError(pc);}}}}\n'


def fixture(data,fields):
    """Retain original Code attributes verbatim, no class initializer/game startup.
    Access flags in temporary fixture only widened for the independent oracle.
    """
    u2=lambda pos:struct.unpack_from('>H',data,pos)[0]
    u4=lambda pos:struct.unpack_from('>I',data,pos)[0]
    if data[:4]!=b'\xca\xfe\xba\xbe':raise ValueError('class magic')
    n=u2(8);p=10;cp={};i=1
    while i<n:
        tag=data[p];p+=1
        if tag==1:
            size=u2(p);p+=2;cp[i]=data[p:p+size].decode('utf-8',errors='replace');p+=size
        elif tag in (3,4,9,10,11,12,17,18):p+=4
        elif tag in (5,6):p+=8;i+=1
        elif tag in (7,8,16,19,20):p+=2
        elif tag==15:p+=3
        else:raise ValueError('CP tag')
        i+=1
    p+=6;interfaces=u2(p);p+=2+2*interfaces;head=data[:p]
    def members(p,wanted):
        total=u2(p);p+=2;out=[];found=set()
        for _ in range(total):
            start=p;flags=u2(p);name=cp[u2(p+2)];desc=cp[u2(p+4)];ac=u2(p+6);p+=8
            for _ in range(ac):p+=6+u4(p+2)
            if (name,desc) in wanted:
                if not flags&8 or flags&(0x20|0x40|0x100|0x400):raise ValueError('unsupported member flags')
                out.append(struct.pack('>H',(flags&~7)|1)+data[start+2:p]);found.add((name,desc))
        if found!=wanted:raise ValueError('fixture missing member')
        return p,struct.pack('>H',len(out))+b''.join(out)
    wanted={(name.split('.')[1],t) for name,t in fields if name.startswith(OWNER+'.')}|{('x3','[I')}
    p,f=members(p,wanted);p,m=members(p,{('k1',DESC),('q3','(II)I'),('m3','(II)I')})
    return head+f+m+b'\0\0'

INSTRUMENT=r'''import java.nio.file.*;
import jdk.internal.org.objectweb.asm.*;
public final class Instrument {
 public static void main(String[] a)throws Exception {
  ClassReader r=new ClassReader(Files.readAllBytes(Path.of(a[0])));
  ClassWriter w=new ClassWriter(r,ClassWriter.COMPUTE_MAXS);
  r.accept(new ClassVisitor(Opcodes.ASM8,w){
   public MethodVisitor visitMethod(int access,String name,String desc,String sig,String[] ex){
    MethodVisitor mv=super.visitMethod(access,name,desc,sig,ex);
    if(!name.equals("k1")||!desc.equals("(LClass_hvi;)V"))return mv;
    return new MethodVisitor(Opcodes.ASM8,mv){
     void step(){super.visitMethodInsn(Opcodes.INVOKESTATIC,"Trace","step","()V",false);}
     public void visitInsn(int op){step();super.visitInsn(op);}
     public void visitIntInsn(int op,int v){step();super.visitIntInsn(op,v);}
     public void visitVarInsn(int op,int v){step();super.visitVarInsn(op,v);}
     public void visitIincInsn(int v,int n){step();super.visitIincInsn(v,n);}
     public void visitJumpInsn(int op,Label l){step();super.visitJumpInsn(op,l);}
     public void visitMethodInsn(int op,String o,String n,String d,boolean it){step();super.visitMethodInsn(op,o,n,d,it);}
     public void visitFieldInsn(int op,String o,String n,String d){
      step();if(op==Opcodes.PUTSTATIC){if(!o.equals("Class_hii")||!d.equals("I"))throw new AssertionError();super.visitInsn(Opcodes.DUP);super.visitLdcInsn(n);super.visitMethodInsn(Opcodes.INVOKESTATIC,"Trace","write","(ILjava/lang/String;)V",false);}
      super.visitFieldInsn(op,o,n,d);
      if(op==Opcodes.GETSTATIC){super.visitInsn(Opcodes.DUP);super.visitLdcInsn(o+"."+n);super.visitMethodInsn(Opcodes.INVOKESTATIC,"Trace","read",(d.equals("I")||d.equals("B"))?"(ILjava/lang/String;)V":"(Ljava/lang/Object;Ljava/lang/String;)V",false);}
     }
    };
   }
  },0);
  Files.write(Path.of(a[1]),w.toByteArray());
 }
}
'''
TRACE=r'''import java.util.*;
public final class Trace {
 static boolean enabled; static long steps,reads,writes; static ArrayList<Object> events=new ArrayList<>();
 public static void read(int v,String n){if(!enabled)return;reads++;events.add("R:"+n);events.add(v);}
 public static void read(Object v,String n){if(!enabled)return;reads++;events.add("R:"+n);events.add(v);}
 public static void step(){steps++;}
 public static void write(int v,String n){if(!enabled)return;int k=switch(n){case "a2"->1;case "b2"->2;case "d2"->3;case "c2"->4;default->throw new AssertionError(n);};writes++;events.add(((long)k<<32)|(v&0xffffffffL));}
 static void reset(){steps=reads=writes=0;events.clear();}
}
'''
HARNESS=r'''import java.util.*;
public class Check {
 static Class_hvi receiver=new Class_hvi(); static Random r=new Random(20261126);
 static int[] bits={0,16,64,256,512,128,32,1024,16|64,16|256,16|512};
 static String run(boolean residual){
  String fault="ok";
  try {if(residual)Residual.run(receiver);else Class_hii.k1(receiver);}
  catch(Throwable e){fault=e.getClass().getName();}
  return fault+":"+Class_hii.a2+":"+Class_hii.b2+":"+Class_hii.d2+":"+Class_hii.c2;
 }
 static void reset(int a,int b,int c,int d){Class_hii.a2=a;Class_hii.b2=b;Class_hii.c2=c;Class_hii.d2=d;}
 public static void main(String[] args){
  int count=0, faults=0, changed=0; long draws=0, originalSteps=0,residualSteps=0,writes=0,reads=0; boolean traced=args.length>0;Trace.enabled=traced;
  for(int n=0;n<(traced?2000:12000);n++){
   int w=1+r.nextInt(12),h=1+r.nextInt(12);Class_hii.j1=w;Class_hii.r3=n%10;
   Class_hii.u3=new char[w*h];Class_hii.x3=new int[w*h];
   for(int j=0;j<w*h;j++){Class_hii.u3[j]=(char)r.nextInt(100);Class_hii.x3[j]=bits[r.nextInt(bits.length)];}
   Class_hii.d4=(byte)(n%37==0?0:24);Class_hac.r24=0;Class_hac.v25=0;Class_hac.y26=w;Class_hac.b28=h;
   Class_hac.b20=r.nextInt();Class_hac.e10=r.nextInt();Class_hxb.s5=r.nextInt();
   if(n%31==0)Class_hii.u3=null;if(n%41==0)Class_hii.x3=null;
   if(n%43==0)Class_hac.y26=w+1;if(n%47==0)Class_hac.b28=h+1;
   int a=r.nextInt(),b=r.nextInt(),c=r.nextInt(),d=r.nextInt();reset(a,b,c,d);
   Class_hvi.draws=0;Trace.reset();String x=run(false);draws+=Class_hvi.draws;originalSteps+=Trace.steps;ArrayList<Object> expected=new ArrayList<>(Trace.events);writes+=Trace.writes;reads+=Trace.reads;
   if(!x.startsWith("ok:"))faults++;if(!x.equals("ok:"+a+":"+b+":"+d+":"+c))changed++;
   reset(a,b,c,d);Trace.reset();String y=run(true);residualSteps+=Trace.steps;
   if(traced&&!expected.equals(Trace.events))throw new AssertionError("read/write order or value "+n);
   if(!x.equals(y))throw new AssertionError(n+" "+x+" != "+y);
   count++;
  }
  System.out.println("PASS cases="+count+" faults="+faults+" changed_or_fault="+changed+" original_draws="+draws+" original_steps="+originalSteps+" residual_steps="+residualSteps+" traced_reads="+reads+" traced_writes="+writes);
 }
}
'''

def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('jar',type=Path);a=p.parse_args()
    digest=hashlib.sha256(a.jar.read_bytes()).hexdigest()
    if digest!=SHA:raise ValueError('unrecognized corpus SHA')
    ins=disassemble(a.jar);ops,fields,writes=lower(ins);entry,residual=reduce(ops)
    report={'sha256':digest,'original_ops':len(ops),'residual_ops':sum(bool(o.code) for o in residual.values()),'writes':writes,'static_read_sites':sum(op=='getstatic' for _,op,_ in ins),'runtime_authorized':False}
    print(json.dumps(report),flush=True)
    with tempfile.TemporaryDirectory() as td:
        root=Path(td);pkg=root/'javax/microedition/lcdui';pkg.mkdir(parents=True)
        with zipfile.ZipFile(a.jar) as z:(root/(OWNER+'.class')).write_bytes(fixture(z.read(OWNER+'.class'),fields))
        (pkg/'Image.java').write_text('package javax.microedition.lcdui; public class Image {}\n')
        (root/'Class_hvi.java').write_text('public final class Class_hvi {static long draws; public final void a(javax.microedition.lcdui.Image i,int a,int b,int c,int d,int e,int f,int g,int h){draws++;}}\n')
        for owner in ('Class_hac','Class_hxb'):
            names=sorted(name.split('.')[1] for name,t in fields if name.startswith(owner+'.') and t=='I')
            (root/(owner+'.java')).write_text('public final class '+owner+' {public static int '+','.join(names)+';}\n')
        (root/'Residual.java').write_text(emit(entry,residual));(root/'Check.java').write_text(HARNESS)
        (root/'Trace.java').write_text(TRACE)
        subprocess.run(['javac','-classpath',td,'-d',td,*map(str,root.rglob('*.java'))],check=True,timeout=30)
        subprocess.run(['java','-Xint','-Xverify:all','-cp',td,'Check'],check=True,timeout=60)
        (root/'Instrument.java').write_text(INSTRUMENT)
        export='java.base/jdk.internal.org.objectweb.asm=ALL-UNNAMED'
        subprocess.run(['javac','--add-exports',export,'-d',td,str(root/'Instrument.java')],check=True,timeout=30)
        traced=root/'traced';traced.mkdir()
        subprocess.run(['java','--add-exports',export,'-cp',td,'Instrument',str(root/(OWNER+'.class')),str(traced/(OWNER+'.class'))],check=True,timeout=30)
        subprocess.run(['java','-Xint','-Xverify:all','-cp',str(traced)+':'+td,'Check','trace'],check=True,timeout=90)
if __name__=='__main__':main()
