#!/usr/bin/env python3
"""Corpus-free real MiniJVM ancestry fixture. No game or LCDUI code shipped.

The production Nick gate pins its own 58/30/5 callsite constants; this test
supplies separately discovered synthetic PCs to the same binding predicate.
"""
import argparse
from pathlib import Path
import re
import subprocess

SOURCES={
"javax/microedition/lcdui/Graphics.java":'''package javax.microedition.lcdui;
public class Graphics {
    public long nativeContext;
    public boolean ownsContext,treoPixelDependent,headless;
    public Graphics(long ctx){nativeContext=ctx;}
}''',
"javax/microedition/lcdui/Canvas.java":'''package javax.microedition.lcdui;
public abstract class Canvas {
    private Graphics graphics;
    private long nativeContext;
    public boolean treoUsesExplicitBuffer;
    protected Canvas(Graphics target,long ctx){graphics=target;nativeContext=ctx;}
    protected abstract void paint(Graphics g);
    public void doPaint(){paint(graphics);}
}''',
"Class_hvi.java":'''public final class Class_hvi {
    public javax.microedition.lcdui.Graphics a;
    public Class_hvi(javax.microedition.lcdui.Graphics g){a=g;}
}''',
"Class_bs.java":'''public abstract class Class_bs {
    protected abstract void a(javax.microedition.lcdui.Graphics g);
}''',
"Class_hef.java":'''public final class Class_hef extends javax.microedition.lcdui.Canvas {
    public static Class_hef g;
    private Class_bs b;
    public Class_hef(javax.microedition.lcdui.Graphics target,long ctx){super(target,ctx);}
    public void set(Class_bs x){b=x;}
    protected final void paint(javax.microedition.lcdui.Graphics g){b.a(g);}
}''',
"Class_hxb.java":'''public final class Class_hxb extends Class_bs {
    private Class_hvi c3=new Class_hvi(null);
    public boolean wrongBinding;
    protected final void a(javax.microedition.lcdui.Graphics g){
        c3.a=wrongBinding?null:g;
        Class_hmi.m(c3);
    }
}''',
"Class_hmi.java":'''public final class Class_hmi {
    public static void m(Class_hvi w){Class_hii.k1(w);}
}''',
"Class_hii.java":'''public final class Class_hii {
    public static int expected,touch;
    public static final void k1(Class_hvi w){touch++;}
}''',
"BindingMain.java":'''public final class BindingMain {
    public static void main(String[] args) {
        javax.microedition.lcdui.Graphics g=new javax.microedition.lcdui.Graphics(12345L);
        Class_hef c=new Class_hef(g,12345L);
        Class_hxb d=new Class_hxb();c.set(d);Class_hef.g=c;
        Class_hvi off=new Class_hvi(g);
        for(int i=0;i<1000;i++){
            Class_hii.expected=1;c.doPaint();
            Class_hii.expected=0;
            Class_hmi.m(off);                  // no paint ancestry
            Class_hii.k1(null);                // no wrapper
            g.ownsContext=true;c.doPaint();g.ownsContext=false;
            g.treoPixelDependent=true;c.doPaint();g.treoPixelDependent=false;
            g.headless=true;c.doPaint();g.headless=false;
            c.treoUsesExplicitBuffer=true;c.doPaint();c.treoUsesExplicitBuffer=false;
            g.nativeContext=54321L;c.doPaint();g.nativeContext=12345L;
            Class_hef.g=null;c.doPaint();Class_hef.g=c;
            d.wrongBinding=true;c.doPaint();d.wrongBinding=false;
            if(i%100==0)System.gc();
        }
        if(Class_hii.touch!=10000)throw new IllegalStateException("missing invocation");
    }
}'''
}

def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('root',type=Path);p.add_argument('header',type=Path);a=p.parse_args()
    src=a.root/'src';classes=a.root/'classes';classes.mkdir(parents=True,exist_ok=False)
    for name,body in SOURCES.items():
        f=src/name;f.parent.mkdir(parents=True,exist_ok=True);f.write_text(body)
    subprocess.run(['javac','--release','8','-d',str(classes),*map(str,src.rglob('*.java'))],check=True)
    def pc(owner,symbol):
        code=subprocess.check_output(['javap','-p','-c','-classpath',str(classes),owner],text=True)
        matches=[int(m[1]) for line in code.splitlines() if symbol in line
                 if (m:=re.match(r'\s*(\d+):\s+invoke(?:static|virtual)\s+',line))]
        if len(matches)!=1:raise ValueError('ambiguous fixture callsite '+symbol)
        return matches[0]
    values=(pc('Class_hmi','Method Class_hii.k1:(LClass_hvi;)V'),
            pc('Class_hxb','Method Class_hmi.m:(LClass_hvi;)V'),
            pc('Class_hef','Method Class_bs.a:(Ljavax/microedition/lcdui/Graphics;)V'))
    a.header.write_text('/* Synthetic fixture only. */\n'+
        '\n'.join(f'#define JBR_TEST_{key}_PC {value}' for key,value in zip(('MAP','DELEGATE','PAINT'),values))+'\n')
    print('binding fixture PCs:',values)
if __name__=='__main__':main()
