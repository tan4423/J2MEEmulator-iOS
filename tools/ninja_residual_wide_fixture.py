#!/usr/bin/env python3
"""Stateful r2-shaped fixture. Only original Java code is loaded by both VMs."""
from pathlib import Path
import re, subprocess, sys
from ninja_residual_native import encode

SOURCES={
'javax/microedition/lcdui/Image.java':'''package javax.microedition.lcdui;
public final class Image { public final int id; public Image(int i){id=i;} }''',
'javax/microedition/lcdui/Graphics.java':'''package javax.microedition.lcdui;
public final class Graphics {
    public static boolean scope;
    public static int remaining,calls,count;
    public static int[] trace=new int[8192];
    public int tx,ty,cx,cy,cw,ch,color,stateCalls;
    public void translate(int x,int y){tx+=x;ty+=y;stateCalls++;}
    public void setClip(int x,int y,int w,int h){cx=x;cy=y;cw=w;ch=h;stateCalls++;}
    public void setColor(int c){color=c&0xffffff;stateCalls++;}
    public void draw(int tag,int x,int y,int w,int h){
        if(scope)return;
        if(count+12>trace.length)throw new IllegalStateException("trace overflow");
        trace[count++]=tag;trace[count++]=x+tx;trace[count++]=y+ty;trace[count++]=w;trace[count++]=h;
        trace[count++]=color;trace[count++]=cx;trace[count++]=cy;trace[count++]=cw;trace[count++]=ch;
        trace[count++]=tx;trace[count++]=ty;calls++;
    }
    public void drawImage(Image i,int x,int y,int anchor){if(i!=null)draw(i.id,x,y,anchor,0);}
}''',
'Class_hvi.java':'''public final class Class_hvi {
    public javax.microedition.lcdui.Graphics a;
    public static int g=1;
    public Class_hvi(javax.microedition.lcdui.Graphics target){a=target;}
    public void a(int x,int y){a.translate(x*g,y*g);}
    public void d(int x,int y,int w,int h){a.setClip(x*g,y*g,w*g,h*g);}
    public void a(int c){a.setColor(c);}
    public void b(int x,int y,int w,int h){a.draw(-1,x*g,y*g,w*g,h*g);}
    public void c(int x,int y,int w,int h){a.draw(-2,x*g,y*g,w*g,h*g);}
    public void a(javax.microedition.lcdui.Image i,int x,int y,int anchor){a.drawImage(i,x*g,y*g,anchor);}
}''',
'Class_hyg.java':'''public final class Class_hyg {
    public static int resets;
    public static void l(Class_hvi g){resets++;g.a(-g.a.tx,-g.a.ty);g.d(0,0,100,100);}
}''',
'Marker.java':'''public final class Marker {
    public int x,y; public short v;
    public Marker(int x,int y,short v){this.x=x;this.y=y;this.v=v;}
}''',
'Class_hjf.java':'''public final class Class_hjf {
    public static int accesses;
    private Object[] items;
    public Class_hjf(Object[] a){items=a;}
    public synchronized int size(){accesses++;return items.length;}
    public synchronized Object elementAt(int n){
        accesses++;
        if(--javax.microedition.lcdui.Graphics.remaining<=0)javax.microedition.lcdui.Graphics.scope=false;
        return items[n];
    }
}''',
'Class_hii.java':'''public final class Class_hii {
    public static int t2,width,height,blink;
    public static int[] palette;
    public static Class_hjf list,other;
    public static Class_hjf[] lists;
    public static Marker current;
    public static javax.microedition.lcdui.Image sprite;
    public static void k1(Class_hvi g){
        if(width<1)return;
        Class_hyg.l(g);g.a(1,2);g.d(0,0,width,height);
        for(int i=0;i<2;i++){
            g.a(palette[i]);g.b(i-2,i-2,width-(i<<1),height-(i<<1));
        }
        g.a(sprite,0,0,0);
        for(int i=0;i<list.size();i++){
            Marker m=(Marker)list.elementAt(i);
            int x=m.x/12,y=m.y/12;
            if(x<0)x=0;if(y<0)y=0;if(x>width)x=width;if(y>height)y=height;
            if(blink%10<8){
                g.a(16777215);g.c(x-2,y-2,5,5);
                g.a(m.v==1?255:16711935);g.c(x-1,y-1,3,3);
            }
        }
        int x=current.x/12,y=current.y/12;
        g.a(16711680);g.c(x,y,3,3);
        for(int i=0;i<lists[0].size();i++){
            x=((Integer)lists[0].elementAt(i)).intValue()/12;
            y=x+2;
            g.a(16777215);g.c(x-1,y-1,3,3);
        }
        for(int i=0;i<other.size();i++){
            Marker m=(Marker)other.elementAt(i);
            if(m!=null&&m!=current){
                x=m.x/12;y=m.y/12;
                g.a(65280);g.c(x-1,y-1,3,3);
                t2=x+y;
            }
        }
        Class_hyg.l(g);
    }
}''',
'ResidualMain.java':r'''import java.io.FileOutputStream;
public final class ResidualMain {
    public static void main(String[] args)throws Exception{
        FileOutputStream out=new FileOutputStream(args[1]+"/residual.txt");
        int faults=0,changed=0;
        for(int n=0;n<2000;n++){
            javax.microedition.lcdui.Graphics g=new javax.microedition.lcdui.Graphics();
            Class_hii.width=1+n%23;Class_hii.height=1+n%31;Class_hii.blink=n;
            Class_hii.palette=n%37==0?null:new int[]{n,~n};
            Marker m=new Marker(n-500,3*n-1000,(short)(n%3));
            Class_hii.current=m;Class_hii.sprite=n%71==0?null:new javax.microedition.lcdui.Image(4);
            Class_hii.list=new Class_hjf(new Object[]{n%41==0?null:n%43==0?(Object)new Integer(1):m,new Marker(-n,n,(short)2)});
            Class_hii.other=new Class_hjf(new Object[]{null,m,new Marker(n*2,n*3,(short)1)});
            Class_hii.lists=new Class_hjf[]{new Class_hjf(new Object[]{new Integer(n)})};
            Class_hii.t2=-100;Class_hjf.accesses=0;Class_hyg.resets=0;Class_hvi.g=1+n%3;
            Class_hvi receiver=n%53==0?null:new Class_hvi(n%59==0?null:g);
            javax.microedition.lcdui.Graphics.scope=n%4!=0;
            javax.microedition.lcdui.Graphics.remaining=1+n%7;
            javax.microedition.lcdui.Graphics.calls=javax.microedition.lcdui.Graphics.count=0;
            int fault=0;
            try{Class_hii.k1(receiver);}
            catch(NullPointerException e){fault=1;}
            catch(ArrayIndexOutOfBoundsException e){fault=2;}
            catch(ArithmeticException e){fault=3;}
            catch(ClassCastException e){fault=4;}
            if(fault!=0)faults++;if(Class_hii.t2!=-100)changed++;
            StringBuilder t=new StringBuilder(n+":"+fault+":"+Class_hii.t2+":"+Class_hjf.accesses+":"+Class_hyg.resets+":"+g.stateCalls+":"+g.tx+":"+g.ty+":"+g.cx+":"+g.cy+":"+g.cw+":"+g.ch+":"+g.color+":"+javax.microedition.lcdui.Graphics.calls);
            for(int k=0;k<javax.microedition.lcdui.Graphics.count;k++){t.append(':');t.append(javax.microedition.lcdui.Graphics.trace[k]);}
            t.append((char)10);out.write(t.toString().getBytes());
            if(n%100==0){System.gc();Thread.sleep(10);}
        }
        if(faults==0||changed==0)throw new IllegalStateException("vacuous fixture");
        out.write(("PASS 2000 "+faults+" "+changed+"\n").getBytes());out.close();
    }
}'''
}

def build(root,header,boot,background=False):
    sources=dict(SOURCES)
    if background:
        sources['Class_hii.java']=sources['Class_hii.java'].replace('public static int[] palette;',
            'public static int[] palette,offsets; public static javax.microedition.lcdui.Image[] frames;')
        # Array faults inside a removable draw, a wide induction update and a
        # length-driven loop. Retained list calls can close the sink between them.
        sources['Class_hii.java']=sources['Class_hii.java'].replace('g.a(sprite,0,0,0);',
            'g.a(sprite,0,0,0); for(int i=0;i<385;i+=192)g.a(frames[0],i,offsets[0],0);')
        sources['Class_hii.java']=sources['Class_hii.java'].replace('int x=current.x/12,y=current.y/12;',
            'for(int i=0;i<frames.length;i++)g.a(frames[i],i,offsets[i],0); int x=current.x/12,y=current.y/12;')
        sources['ResidualMain.java']=sources['ResidualMain.java'].replace('Class_hii.t2=-100;',
            'Class_hii.frames=n%47==0?null:new javax.microedition.lcdui.Image[]{Class_hii.sprite,null}; Class_hii.offsets=n%61==0?new int[0]:n%67==0?null:new int[]{n,-n}; Class_hii.t2=-100;')
    src=root/'src';classes=root/'classes';classes.mkdir(parents=True)
    for name,body in sources.items():
        p=src/name;p.parent.mkdir(parents=True,exist_ok=True);p.write_text(body)
    subprocess.run(['javac','--release','8','-d',str(classes),*map(str,src.rglob('*.java'))],check=True)
    subprocess.run(['javac','-source','8','-target','8','-bootclasspath',str(boot),'-classpath',str(classes),'-d',str(classes),str(src/'ResidualMain.java')],check=True)
    text=subprocess.check_output(['javap','-p','-c','-classpath',str(classes),'Class_hii'],text=True)
    block=text.split('void k1(Class_hvi);',1)[1].split('\n\n',1)[0]
    ins=[(int(m[1]),m[2],m[3].strip()) for line in block.splitlines() if (m:=re.match(r'\s*(\d+):\s+(\w+)\s*(.*)',line))]
    code=encode(ins,'<')
    if not {'getfield','checkcast','aaload','iaload','invokevirtual','invokestatic','if_acmpeq','astore_2','astore'}<=set(o for _,o,_ in ins):
        raise ValueError('missing stateful fixture coverage')
    extra=''
    if background:
        # Independently locate receiver starts for the two actual array draws.
        starts=[]
        for i,(pc,op,arg) in enumerate(ins):
            if op=='invokevirtual' and 'Image;III)V' in arg:
                j=i-1
                while j>=0 and ins[j][1]!='aload_0':j-=1
                if j>=0 and any(o=='aaload' for _,o,_ in ins[j:i]):starts.append(ins[j][0])
        if len(starts)!=2 or not {'iinc_w','arraylength'}<=set(o for _,o,_ in ins):raise ValueError('missing background coverage')
        extra=f'#define JBR_TEST_BG_WIDE_PC {starts[0]}\n#define JBR_TEST_BG_ARRAY_PC {starts[1]}\n'
    header.write_text(extra+'static const int jbr_draw_effects=0,jbr_resume=1,jbr_resolved_reads=0,jbr_skip_draws=1;\n'+
        'static const unsigned char jbr_expected_code[]={'+','.join(map(str,code))+'};\n'+
        'static const JarBoxResidualOp jbr_plan[]={{0}}; /* independent original Java execution */\n')
    print('stateful whole-loop fixture:',len(ins),'instructions,',len(code),'bytes')
if __name__=='__main__':build(*map(Path,sys.argv[1:4]),background='--background' in sys.argv[4:])
