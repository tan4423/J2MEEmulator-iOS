#!/usr/bin/env python3
"""Build isolated original/residual class fixtures for the real VM host gate.
No proprietary binaries are needed for the synthetic CI fixture. Optional
local Nick archive uses the already verified exact map-loop compiler profile.
"""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import zipfile

import ninja_map_residual as ir
from ninja_residual_bytecode import emit_bytecode, replace_fixture_code
import ninja_residual_wrapper_fixture as wrapped

SYNTHETIC = '''public class Class_hii {
    static int a2,b2,c2,d2,j1,r3; static byte d4;
    static char[] u3; static int[] x3;
    static javax.microedition.lcdui.Image sprite;
    public static int q3(int x,int y){return x3[y*j1+x];}
    public static int m3(int x,int y){return x3[y*j1+x];}
    public static final void k1(Class_hvi g){
        for(int x=Class_hac.r24;x<Class_hac.y26;x++){
            for(int y=Class_hac.v25;y<Class_hac.b28;y++){
                int tile=u3[y*j1+x]-1;
                if(r3==4 && (q3(x,y)&16)==16){
                    g.a(sprite,x*24,y*24,tile*24,24,0,x+Class_hac.b20,y+Class_hac.e10,0);
                }
                a2=x; b2=y; c2=tile/d4; d2=m3(x,y);
                g.a(sprite,x*24,y*24,tile*24,24,0,x,y,0);
            }
        }
    }
}'''
EXTERNAL = '''public class Class_hac {public static int r24,v25,y26,b28,b20,e10;}'''
WRAPPER = '''public final class Class_hvi {
    public final void a(javax.microedition.lcdui.Image i,int a,int b,int c,int d,int e,int f,int g,int h){}
}'''
HARNESS = '''import java.io.FileOutputStream;
public class ResidualMain {
    static int rng=1289;
    static int next(){rng=rng*1664525+1013904223;return rng;}
    static void check(boolean ok){if(!ok)throw new IllegalStateException("Java integer semantics");}
    static void arithmetic(int a,int b,long c,long d,int n){
        check(a+b==Integer.MIN_VALUE);
        check(a-(-b)==Integer.MIN_VALUE);
        check((a+b)*(-b)==Integer.MIN_VALUE);
        int x=a;x++;check(x==Integer.MIN_VALUE);
        check(-x==Integer.MIN_VALUE);
        check(x/(-b)==Integer.MIN_VALUE&&x%(-b)==0);
        check((x>>n)==-1073741824&&(x>>>n)==1073741824&&(b<<n)==2);
        check(c+d==Long.MIN_VALUE);
        check(c-(-d)==Long.MIN_VALUE);
        long y=c+d;check(-y==Long.MIN_VALUE&&y*(-d)==Long.MIN_VALUE);
        check(y/(-d)==Long.MIN_VALUE&&y%(-d)==0);
        check((y>>(n+32))==-4611686018427387904L&&(y>>>(n+32))==4611686018427387904L&&(d<<(n+32))==2L);
        boolean zero=false;try{int z=a/(b-b);check(z==1);}catch(ArithmeticException e){zero=true;}check(zero);
    }
    public static void main(String[] args)throws Exception{
        arithmetic(Integer.MAX_VALUE,1,Long.MAX_VALUE,1L,33);
        arithmetic(Integer.MAX_VALUE,1,Long.MAX_VALUE,1L,-31);
        FileOutputStream out=new FileOutputStream(args[1]+"/residual.txt");
        Class_hvi receiver=new Class_hvi();
        int faults=0,changed=0;
        for(int n=0;n<2000;n++){
            int w=1+(next()&7),h=1+(next()&7);
            Class_hii.j1=w;Class_hii.r3=n%10;Class_hii.d4=(byte)(n%37==0?0:24);
            Class_hii.u3=new char[w*h];Class_hii.x3=new int[w*h];
            for(int i=0;i<w*h;i++){Class_hii.u3[i]=(char)(next()&127);Class_hii.x3[i]=next()&2047;}
            Class_hac.r24=0;Class_hac.v25=0;Class_hac.y26=w;Class_hac.b28=h;
            Class_hac.b20=next();Class_hac.e10=next();Class_hxb.s5=next();
            if(n%31==0)Class_hii.u3=null;if(n%41==0)Class_hii.x3=null;
            if(n%43==0)Class_hac.y26=w+1;if(n%47==0)Class_hac.b28=h+1;
            int a=next(),b=next(),c=next(),d=next();
            Class_hii.a2=a;Class_hii.b2=b;Class_hii.c2=c;Class_hii.d2=d;
            int fault=0;
            try {Class_hii.k1(receiver);}
            catch(NullPointerException e){fault=1;}
            catch(ArrayIndexOutOfBoundsException e){fault=2;}
            catch(ArithmeticException e){fault=3;}
            if(fault!=0)faults++;
            if(a!=Class_hii.a2||b!=Class_hii.b2||c!=Class_hii.c2||d!=Class_hii.d2)changed++;
            String line=n+":"+fault+":"+Class_hii.a2+":"+Class_hii.b2+":"+Class_hii.c2+":"+Class_hii.d2+"\\n";
            out.write(line.getBytes());
            if(n%100==0){System.gc();Thread.sleep(10);}
        }
        if(faults==0||changed==0)throw new IllegalStateException("vacuous fixture");
        out.write(("PASS 2000 "+faults+" "+changed+"\\n").getBytes());out.close();
    }
}'''


def build(root, archive=None, bootclasspath=None, draw_effects=False, resume=False, resolved_reads=False):
    if resolved_reads and (archive is not None or not draw_effects or resume):
        raise ValueError('resolved-read CI fixture is synthetic, with draw effects and no resume')
    if resume and not draw_effects:raise ValueError('resume requires draw effects')
    root=Path(root).resolve()
    src=root/'src'; original=root/'original'; residual=root/'residual'
    for d in (src,original,residual): d.mkdir(parents=True,exist_ok=False)
    (src/'Class_hvi.java').write_text(wrapped.WRAPPER if draw_effects else WRAPPER)
    pkg=src/'javax/microedition/lcdui';pkg.mkdir(parents=True)
    # Test double, deliberately not the real LCDUI Image. Never packaged.
    (pkg/'Image.java').write_text(wrapped.IMAGE if draw_effects else 'package javax.microedition.lcdui; public class Image {}')
    if draw_effects: (pkg/'Graphics.java').write_text(wrapped.graphics_source(resume))
    if archive is None:
        synthetic=SYNTHETIC
        external=EXTERNAL
        if resolved_reads:
            # A not-yet-resolved CP read whose result is draw-only, and a
            # volatile read in an otherwise dead argument computation.
            synthetic=synthetic.replace('                a2=x;', '                if(r3==9)g.a(sprite,Class_hxb.s5,24,24,24,0,0,0,0);\n                a2=x;')
            external='public class Class_hac {public static int r24,v25,y26,b28,e10; public static volatile int b20;}'
        (src/'Class_hii.java').write_text(synthetic)
        (src/'Class_hac.java').write_text(external)
        (src/'Class_hxb.java').write_text('public class Class_hxb {public static int s5;}')
        subprocess.run(['javac','--release','8','-d',str(original),*map(str,src.rglob('*.java'))],check=True)
        ins=ir.disassemble(original)
        data=(original/'Class_hii.class').read_bytes()
        # Only the synthetic, simple legacy-CP class; no modern CP entries are
        # admitted by replace_fixture_code. Original game fixture already v47.
        data=data[:6]+b'\x00\x31'+data[8:]
        ops,fields,_=ir.lower(ins,draw_effects=draw_effects)
        data=ir.fixture(data,fields)
    else:
        archive=Path(archive)
        if hashlib.sha256(archive.read_bytes()).hexdigest()!=ir.SHA:raise ValueError('unknown archive')
        ins=ir.disassemble(archive);ops,fields,_=ir.lower(ins,draw_effects=draw_effects)
        with zipfile.ZipFile(archive) as z:data=ir.fixture(z.read(ir.OWNER+'.class'),fields)
        for owner in ('Class_hac','Class_hxb'):
            names={name.split('.')[1] for name,t in fields if name.startswith(owner+'.') and t=='I'}
            names|=set(('r24','v25','y26','b28','b20','e10') if owner=='Class_hac' else ('s5',))
            (src/(owner+'.java')).write_text('public final class '+owner+' {public static int '+','.join(sorted(names))+';}')
        subprocess.run(['javac','--release','8','-d',str(original),*map(str,src.rglob('*.java'))],check=True)
    if archive is not None and draw_effects:
        with zipfile.ZipFile(archive) as z:
            (original/'Class_hvi.class').write_bytes(wrapped.copy_wrapper(z.read('Class_hvi.class')))
    entry,plan=ir.reduce(ops)
    code,locals_count,pc_map=emit_bytecode(ins,entry,plan)
    reduced=replace_fixture_code(data,code,locals_count,max_stack=10 if draw_effects else 2)
    (original/'Class_hii.class').write_bytes(data)
    harness=wrapped.harness(HARNESS,fields,resume) if draw_effects else HARNESS
    if resolved_reads:
        harness=harness.replace('        int faults=0,changed=0;', '''        // Natural resolution, one complete ordinary k1 invocation. r3=9
        // stays cold. Do not initialize game classes early in a live VM.
        Class_hii.j1=1;Class_hii.r3=4;Class_hii.d4=24;
        Class_hii.u3=new char[]{1};Class_hii.x3=new int[]{16};
        Class_hac.r24=Class_hac.v25=0;Class_hac.y26=Class_hac.b28=1;
        Class_hii.k1(new Class_hvi(target));
        if(javax.microedition.lcdui.Graphics.calls!=2)throw new IllegalStateException("warmup coverage");
        int faults=0,changed=0;''')
    (src/'ResidualMain.java').write_text(harness)
    flags=['-source','8','-target','8','-bootclasspath',str(bootclasspath)] if bootclasspath else ['--release','8']
    subprocess.run(['javac',*flags,'-classpath',str(original),'-d',str(original),str(src/'ResidualMain.java')],check=True)
    for file in original.rglob('*.class'):
        dest=residual/file.relative_to(original);dest.parent.mkdir(parents=True,exist_ok=True)
        dest.write_bytes(reduced if file.name=='Class_hii.class' else file.read_bytes())
    report={'runtime_authorized':False,'original_ops':len(ops),'residual_ops':sum(bool(o.code) for o in plan.values()),'fixture_bytecode_bytes':len(code),'effect_pc_map':pc_map}
    (root/'plan.json').write_text(json.dumps(report,indent=2)+'\n')
    print({k:v for k,v in report.items() if k!='effect_pc_map'})


def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('root',type=Path);p.add_argument('--archive',type=Path);p.add_argument('--bootclasspath',type=Path);p.add_argument('--draw-effects',action='store_true');p.add_argument('--resume',action='store_true');p.add_argument('--resolved-reads',action='store_true');a=p.parse_args()
    build(a.root,a.archive,a.bootclasspath,a.draw_effects,a.resume,a.resolved_reads)
if __name__=='__main__':main()
