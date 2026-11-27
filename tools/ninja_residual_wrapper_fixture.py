"""Exact original draw wrapper fixture; controlled screen sink only."""
import struct

GRAPHICS = '''package javax.microedition.lcdui;
public final class Graphics {
    public static int calls; public static char[] order=new char[512];
    public void drawRegion(Image src,int x,int y,int w,int h,int t,int dx,int dy,int anchor){
        if(calls>=order.length)throw new IllegalStateException("draw trace overflow");
        order[calls++]=(char)(65+(src==null?0:src.id));
    }
}'''
IMAGE = '''package javax.microedition.lcdui;
public class Image { public final int id; public Image(int id){this.id=id;} }'''
WRAPPER = '''public final class Class_hvi {
    public static int g=1;
    public javax.microedition.lcdui.Graphics a;
    public Class_hvi(javax.microedition.lcdui.Graphics target){a=target;}
    public final void a(javax.microedition.lcdui.Image i,int x,int y,int w,int h,int t,int dx,int dy,int anchor){
        dx*=g;dy*=g;x*=g;y*=g;w*=g;h*=g;
        a.drawRegion(i,x,y,w,h,t,dx,dy,anchor);
    }
}'''


def copy_wrapper(data):
    """Preserve exact selected member bytes including Code and original CP."""
    u2=lambda p:struct.unpack_from('>H',data,p)[0]
    u4=lambda p:struct.unpack_from('>I',data,p)[0]
    if data[:4]!=b'\xca\xfe\xba\xbe' or not 45<=u2(6)<=49:raise ValueError('wrapper version')
    p=10;i=1;cp={}
    while i<u2(8):
        tag=data[p];p+=1
        if tag==1:
            n=u2(p);p+=2;cp[i]=data[p:p+n].decode('utf8',errors='replace');p+=n
        elif tag in (3,4,9,10,11,12):p+=4
        elif tag in (5,6):p+=8;i+=1
        elif tag in (7,8):p+=2
        else:raise ValueError('wrapper CP')
        i+=1
    p+=6;p+=2+2*u2(p);head=data[:p]
    def members(p,wanted):
        count=u2(p);p+=2;keep=[];found=set()
        for _ in range(count):
            start=p;flags=u2(p);key=(cp[u2(p+2)],cp[u2(p+4)]);ac=u2(p+6);p+=8
            for _ in range(ac):p+=6+u4(p+2)
            if key in wanted:
                if key in found or flags&(0x20|0x100|0x400):raise ValueError('unsupported member')
                keep.append(data[start:p]);found.add(key)
        if found!=wanted:raise ValueError('missing wrapper member')
        return p,struct.pack('>H',len(keep))+b''.join(keep)
    p,fields=members(p,{('g','I'),('a','Ljavax/microedition/lcdui/Graphics;')})
    p,methods=members(p,{('<init>','(Ljavax/microedition/lcdui/Graphics;)V'),('<clinit>','()V'),('a','(Ljavax/microedition/lcdui/Image;IIIIIIII)V')})
    return head+fields+methods+b'\0\0'


def graphics_source(resume,skip_draws=False):
    if skip_draws:
        return graphics_source(True).replace('public static int calls,limit,count;', 'public static int calls,limit,count,remaining; public static boolean scope;').replace('        if(calls>=order.length)', '        if(scope)return;\n        if(calls>=order.length)').replace('if(calls>limit){','if(true){')
    if not resume:return GRAPHICS
    # Model a scope ending BETWEEN draw calls. Before the limit the sink
    # ignores coordinates; after it, every original integer is observable.
    return GRAPHICS.replace('public static int calls;', 'public static int calls,limit,count; public static int[] coords=new int[4096];').replace(
        'order[calls++]=(char)(65+(src==null?0:src.id));',
        '''order[calls++]=(char)(65+(src==null?0:src.id));
        if(calls>limit){
            if(count+8>coords.length)throw new IllegalStateException("coord trace overflow");
            coords[count++]=x;coords[count++]=y;coords[count++]=w;coords[count++]=h;
            coords[count++]=t;coords[count++]=dx;coords[count++]=dy;coords[count++]=anchor;
        }''')


def harness(base, fields, resume=False, skip_draws=False):
    # Preserve original receiver and source-image identity. Exercise null
    # wrapper and null graphics target; the controlled sink ignores int args.
    base=base.replace('Class_hvi receiver=new Class_hvi();','javax.microedition.lcdui.Graphics target=new javax.microedition.lcdui.Graphics();')
    images=sorted(name for name,desc in fields if desc=='Ljavax/microedition/lcdui/Image;')
    setup='\n'.join(f'            {name}=n%71==0?null:new javax.microedition.lcdui.Image({i+1});' for i,name in enumerate(images))
    base=base.replace('            int fault=0;',setup+'''
            Class_hvi.g=next();
            Class_hvi receiver=n%53==0?null:new Class_hvi(n%59==0?null:target);
            javax.microedition.lcdui.Graphics.calls=0;
            int fault=0;''')
    base=base.replace('Class_hii.d2+"\\n"','Class_hii.d2+":"+javax.microedition.lcdui.Graphics.calls+":"+new String(javax.microedition.lcdui.Graphics.order,0,javax.microedition.lcdui.Graphics.calls)+"\\n"')
    if resume:
        base=base.replace('javax.microedition.lcdui.Graphics.calls=0;', '''javax.microedition.lcdui.Graphics.calls=0;
            javax.microedition.lcdui.Graphics.count=0;
            javax.microedition.lcdui.Graphics.limit=n%4;''')
        # Compare exact ordered coordinates (not merely a collision-prone
        # digest) after leaving the modeled scope, along with fault/state.
        base=base.replace('out.write(line.getBytes());', '''StringBuilder trace=new StringBuilder(line.substring(0,line.length()-1));
            for(int i=0;i<javax.microedition.lcdui.Graphics.count;i++){
                trace.append(':');trace.append(javax.microedition.lcdui.Graphics.coords[i]);
            }
            trace.append((char)10);
            out.write(trace.toString().getBytes());''')
    if skip_draws:
        base=base.replace('javax.microedition.lcdui.Graphics.limit=n%4;', '''javax.microedition.lcdui.Graphics.limit=n%4;
            javax.microedition.lcdui.Graphics.remaining=n%4;
            javax.microedition.lcdui.Graphics.scope=n%4!=0;''')
    return base
