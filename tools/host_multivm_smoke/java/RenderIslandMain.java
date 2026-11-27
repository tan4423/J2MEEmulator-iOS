import java.io.FileOutputStream;

public final class RenderIslandMain {
    static int scale=13;
    static volatile int volatileScale=7;
    static int effects, complexEffects;
    static final class Cold {static int value=init();static int init(){effects+=100;return 23;}}
    static final class Sink {
        boolean closed;
        int sum;
        final void draw(int a,int b,int c,int d) {
            if(!closed) sum=sum*31+a+b+c+d;
        }
    }
    static void frame(Sink s,int n) {
        s.draw((n+2)*3,n-scale,n>>>2,7);
        effects++;
        s.draw(n^17,(n*3)-7,scale,n+9);
        s.draw(n+1,volatileScale,n,2);
    }
    static int effect(int n) { complexEffects++;return n+5; }
    static void complex(Sink s,int[] values,int n,int divisor) {
        s.draw(effect(n),values[n],volatileScale,n/divisor);
    }
    static void cold(Sink s,int n) {s.draw(n+1,Cold.value,n,2);}
    static void fault(Sink s,int n) {s.draw(n+1,n/0,n,2);}
    static void nullFault(Sink s,int n) {s.draw(n+1,n-3,n,2);}
    static void require(boolean b){if(!b)throw new IllegalStateException("render island mismatch");}
    public static void main(String[] args)throws Exception{
        Sink s=new Sink();int oracle=0;int[] values={19,-2,31,7};
        for(int i=0;i<8000;i++){
            s.closed=(i&1)==0;
            frame(s,i);
            complex(s,values,i&3,1);
            if(!s.closed){
                oracle=oracle*31+(i+2)*3+(i-scale)+(i>>>2)+7;
                oracle=oracle*31+(i^17)+(i*3-7)+scale+(i+9);
                oracle=oracle*31+i+1+volatileScale+i+2;
                int n=i&3;oracle=oracle*31+n+5+values[n]+volatileScale+n;
            }
            require(s.sum==oracle&&effects==i+1&&complexEffects==i+1);
            if(i%1000==999){System.gc();Thread.sleep(250);}
        }
        s.closed=true;
        cold(s,1);require(effects==8100&&s.sum==oracle);
        boolean div=false,nul=false;
        try{fault(s,5);}catch(ArithmeticException ex){div=true;}
        try{nullFault(null,5);}catch(NullPointerException ex){nul=true;}
        require(div&&nul);
        boolean bounds=false;div=false;nul=false;
        try{complex(s,values,-1,1);}catch(ArrayIndexOutOfBoundsException ex){bounds=true;}
        try{complex(s,values,2,0);}catch(ArithmeticException ex){div=true;}
        try{complex(null,values,2,1);}catch(NullPointerException ex){nul=true;}
        require(bounds&&div&&nul&&complexEffects==8003&&s.sum==oracle);
        FileOutputStream f=new FileOutputStream(args[1]+"/island.txt");
        f.write("PASS 8000\n".getBytes());f.close();
    }
}
