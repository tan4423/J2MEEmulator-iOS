import java.io.FileOutputStream;

/** Whole-method control flow and observable effects, no game archive. */
public final class BlockMain {
    static final int COUNT=8000;
    static int effects;
    static final class Token {
        final int owner;
        Token(int owner) { this.owner=owner; }
    }
    static int mix(int a,int b) {
        int x=(a*31+b)^(a<<b);
        int y=(x>>>b)+(x>>a)-b;
        int z=(y&0x7fff)|(x^b);
        return ((byte)z+(short)y+(char)x)*3-(-z);
    }
    static long mixLong(long a,long b,int s) {
        long x=(a*31L+b)^(a<<s);
        long y=(x>>>s)+(x>>s)-b;
        long z=(y&0x12345678L)|(x^b);
        return z+(long)(int)y-(-x)+(z<b?1:0);
    }
    static int control(int a,int b,int[] map,Token token,int i) {
        int result=(a+b)*3 ^ (a<<b);
        try {
            switch(i&7) {
                case 0: result=(result+b)*7-a;break;
                case 1: result=(result-b)^a;break;
                case 2: result=(result>>>b)+a;break;
                case 3: result=(result>>b)-a;break;
                default: result=(result*5+b)^a;break;
            }
            switch(i%17) {
                case 1: result+=b;break;
                case 8: result-=b;break;
                case 15: result^=b;break;
                default: break;
            }
            effects++;
            Token copy=token;
            if(copy!=null) result+=copy.owner-token.owner;
            result+=map[(i%13)-1];
            result/=i%11;
        } catch (ArrayIndexOutOfBoundsException ex) {
            result=(result+17)^a;
        } catch (ArithmeticException ex) {
            result=(result-29)^b;
        }
        return result;
    }
    public static void main(String[] args) throws Exception {
        int owner=args[0].charAt(0)*100000;
        Token token=new Token(owner);
        int[] map=new int[12];
        for(int i=0;i<map.length;i++) map[i]=i*7-21;
        long digest=0;
        for(int i=0;i<COUNT;i++) {
            int a=i*1103515245+12345,b=i*17-512;
            int x=mix(a,b);
            long y=mixLong(((long)x<<32)|((long)b&0xffffffffL),((long)a<<17)-b,b);
            int z=control(x,(int)y,map,(i&1)==0?token:null,i);
            digest=digest*31+y+z+x;
            if((i%1000)==999) {
                byte[][] pressure=new byte[64][];
                for(int k=0;k<pressure.length;k++) {
                    pressure[k]=new byte[1024];pressure[k][0]=(byte)k;
                }
                System.gc();Thread.sleep(300);
                if(pressure[63][0]!=63||token.owner!=owner||effects!=i+1)
                    throw new IllegalStateException("owner/root/effect mismatch");
            }
        }
        FileOutputStream out=new FileOutputStream(args[1]+"/block.txt");
        out.write(("PASS "+effects+" "+digest+"\n").getBytes());out.close();
    }
}
