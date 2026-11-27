#!/usr/bin/env python3
"""Synthetic i3-shaped whole-loop differential, never a production game."""
import re
import subprocess
import sys
from pathlib import Path
from ninja_residual_native import encode
import ninja_residual_wrapper_fixture as wrapper

MAP='''public final class Class_hii {
    public static int t2,j1,r3,q2;
    public static short o4;
    public static byte d4;
    public static char[] u3;
    public static int[] bits;
    public static javax.microedition.lcdui.Image s1,s2;
    public static int q3(int x,int y){
        if(--javax.microedition.lcdui.Graphics.remaining<=0)javax.microedition.lcdui.Graphics.scope=false;
        return bits[y*j1+x];
    }
    public static final void k1(Class_hvi g){
        if(Class_hxb.k1)return;
        for(int x=0;x<Class_hac.y26;x++){
            for(int y=0;y<Class_hac.b28;y++){
                javax.microedition.lcdui.Image selected=null;
                if(r3==4)selected=s1;else selected=s2;
                if((q3(x,y)&1)!=0)g.a(s1,x,y,0);
                if((q3(x,y)&2)==2)g.a(selected,0,x*24,24,24,0,x*d4,y*d4,0);
            }
        }
        for(int x=0;x<Class_hac.y26;x++){
            int y=q2;
            int tile=u3[y*j1+x]-1;
            if(o4==64)t2=115;
            if((q3(x,y)&4)!=0)tile=t2;
            if(tile<0)continue;
            for(int j=1;j<=4;j++){
                g.a(s2,0,tile*d4,24,24,0,x*d4,(y+j)*d4,0);
            }
        }
    }
}'''
MAIN=r'''import java.io.FileOutputStream;
public class ResidualMain {
    public static void main(String[] args)throws Exception {
        FileOutputStream out=new FileOutputStream(args[1]+"/residual.txt");
        javax.microedition.lcdui.Graphics target=new javax.microedition.lcdui.Graphics();
        int faults=0,changed=0;
        for(int n=0;n<2000;n++){
            int w=1+n%4,h=1+(n/4)%4;
            Class_hii.j1=w;Class_hii.r3=n%10;Class_hii.q2=h-1;
            Class_hii.o4=(short)(n%2==0?64:7);Class_hii.d4=(byte)(n%256);
            Class_hii.u3=new char[w*h];Class_hii.bits=new int[w*h];
            for(int i=0;i<w*h;i++){Class_hii.u3[i]=(char)((n+i)%8);Class_hii.bits[i]=(n+i)%8;}
            Class_hac.y26=w;Class_hac.b28=h;Class_hxb.k1=n%19==0;
            Class_hii.s1=n%71==0?null:new javax.microedition.lcdui.Image(1);
            Class_hii.s2=new javax.microedition.lcdui.Image(2);
            if(n%31==0)Class_hii.u3=null;
            if(n%41==0)Class_hii.bits=null;
            if(n%43==0)Class_hac.y26=w+1;
            Class_hii.t2=-100;Class_hvi.g=1+n%3;
            Class_hvi receiver=n%53==0?null:new Class_hvi(n%59==0?null:target);
            javax.microedition.lcdui.Graphics.calls=0;
            javax.microedition.lcdui.Graphics.count=0;
            javax.microedition.lcdui.Graphics.scope=n%4!=0;
            javax.microedition.lcdui.Graphics.remaining=1+n%20;
            int fault=0;
            try {Class_hii.k1(receiver);}
            catch(NullPointerException e){fault=1;}
            catch(ArrayIndexOutOfBoundsException e){fault=2;}
            catch(ArithmeticException e){fault=3;}
            if(fault!=0)faults++;
            if(Class_hii.t2!=-100)changed++;
            StringBuilder trace=new StringBuilder(n+":"+fault+":"+Class_hii.t2+":"+javax.microedition.lcdui.Graphics.calls+":"+new String(javax.microedition.lcdui.Graphics.order,0,javax.microedition.lcdui.Graphics.calls));
            for(int i=0;i<javax.microedition.lcdui.Graphics.count;i++){trace.append(':');trace.append(javax.microedition.lcdui.Graphics.coords[i]);}
            trace.append((char)10);out.write(trace.toString().getBytes());
            if(n%100==0){System.gc();Thread.sleep(10);}
        }
        if(faults==0||changed==0)throw new IllegalStateException("vacuous fixture");
        out.write(("PASS 2000 "+faults+" "+changed+"\n").getBytes());out.close();
    }
}'''

def build(root,header,boot):
    src=root/'src';classes=root/'classes';classes.mkdir(parents=True)
    pkg=src/'javax/microedition/lcdui';pkg.mkdir(parents=True)
    (pkg/'Image.java').write_text(wrapper.IMAGE)
    (pkg/'Graphics.java').write_text(wrapper.graphics_source(True,True).replace(
        'public void drawRegion(','''public void drawImage(Image i,int x,int y,int a){drawRegion(i,x,y,-1,-1,-1,x,y,a);}
    public void drawRegion('''))
    (src/'Class_hvi.java').write_text(wrapper.WRAPPER.replace(
        'public final void a(javax.microedition.lcdui.Image i,int x,int y,int w', '''public final void a(javax.microedition.lcdui.Image i,int x,int y,int anchor){a.drawImage(i,x*g,y*g,anchor);}
    public final void a(javax.microedition.lcdui.Image i,int x,int y,int w'''))
    (src/'Class_hii.java').write_text(MAP)
    (src/'Class_hac.java').write_text('public class Class_hac {public static int y26,b28;}')
    (src/'Class_hxb.java').write_text('public class Class_hxb {public static boolean k1;}')
    (src/'ResidualMain.java').write_text(MAIN)
    subprocess.run(['javac','--release','8','-d',str(classes),*map(str,src.rglob('*.java'))],check=True)
    subprocess.run(['javac','-source','8','-target','8','-bootclasspath',str(boot),'-classpath',str(classes),'-d',str(classes),str(src/'ResidualMain.java')],check=True)
    text=subprocess.check_output(['javap','-p','-c','-classpath',str(classes),'Class_hii'],text=True)
    block=text.split('void k1(Class_hvi);',1)[1].split('\n\n',1)[0]
    ins=[(int(m[1]),m[2],m[3].strip()) for line in block.splitlines() if (m:=re.match(r'\s*(\d+):\s+(\w+)\s*(.*)',line))]
    code=encode(ins,'<')
    if not {'astore_3','aload_3','istore_3','iload','istore'}<=set(o for _,o,_ in ins):raise ValueError('missing mixed local coverage')
    header.write_text('static const int jbr_draw_effects=0,jbr_resume=1,jbr_resolved_reads=0,jbr_skip_draws=1;\n'+
        'static const unsigned char jbr_expected_code[]={'+','.join(map(str,code))+'};\n'+
        'static const JarBoxResidualOp jbr_plan[]={{0}}; /* independent Java reference */\n')
    print('mixed local fixture:',len(ins),'instructions,',len(code),'bytes')
if __name__=='__main__':build(*map(Path,sys.argv[1:]))
