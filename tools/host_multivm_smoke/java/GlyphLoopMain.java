import java.io.FileOutputStream;
public final class GlyphLoopMain {
    static final class Sink {
        boolean closed;
        int draws, digest;
        final void region(Object image,int a,int b,int c,int d,int e,int f,int g,int h){
            if(closed)return;
            draws++; digest=digest*31+a+b+c+d+e+f+g+h;
        }
    }
    static final class Wrapper {
        final Sink sink;
        Wrapper(Sink s){sink=s;}
        final void draw(Object image,int a,int b,int c,int d,int e,int f,int g,int h){sink.region(image,a,b,c,d,e,f,g,h);}
    }
    static final class Font {
        String c2;
        int[][] d2;
        int w1=2;
        Object b2=new Object();
        Font(String a,int[][] r){c2=a;d2=r;}
        final int width(String s){int w=0;for(int i=0;i<s.length();i++){int k=c2.indexOf(s.charAt(i));if(k==-1)k=0;w+=d2[k][2]+w1;}return w;}
        final void draw(Wrapper g,String s,int x,int y,int align){
            int n=s.length();
            if(align==0)align=x;else if(align==1)align=x-width(s);else align=x-(width(s)>>1);
            for(int i=0;i<n;i++){
                x=c2.indexOf(s.charAt(i));if(x==-1)x=0;
                if(x>-1)g.draw(b2,d2[x][0],d2[x][1],d2[x][2],d2[x][3],0,align,y,20);
                align+=d2[x][2]+w1;
            }
        }
        final void draw(Wrapper g,String s,int x,int y,int align,Font alt){
            int n=s.length();
            if(align==0)align=x;else if(align==1)align=x-width(s);else align=x-(width(s)>>1);
            for(int i=0;i<n;i++){
                x=c2.indexOf(s.charAt(i));if(x==-1)x=0;
                if(x>-1){
                    g.draw(alt.b2,d2[x][0],d2[x][1],d2[x][2],d2[x][3],0,align+1,y,20);
                    g.draw(alt.b2,d2[x][0],d2[x][1],d2[x][2],d2[x][3],0,align,y+1,20);
                    g.draw(b2,d2[x][0],d2[x][1],d2[x][2],d2[x][3],0,align,y,20);
                }
                align+=d2[x][2]+w1;
            }
        }
    }
    static void require(boolean ok){if(!ok)throw new IllegalStateException("glyph loop mismatch");}
    public static void main(String[] args)throws Exception{
        Sink s=new Sink();Wrapper w=new Wrapper(s);Font f=new Font("abc",new int[][]{{1,2,3,4},{5,6,7,8},{9,10,11,12}});Font alt=new Font("abc",f.d2);
        String text="abzcb";int draws=0,digest=0;
        for(int i=0;i<8000;i++){
            s.closed=(i&1)==0;
            if((i&2)==0)f.draw(w,text,i,7,i%3);else f.draw(w,text,i,7,i%3,alt);
            if(!s.closed){int pos=i;int width=0;for(int j=0;j<text.length();j++){int k=f.c2.indexOf(text.charAt(j));if(k<0)k=0;width+=f.d2[k][2]+f.w1;}if(i%3==1)pos-=width;else if(i%3==2)pos-=width>>1;
                for(int j=0;j<text.length();j++){int k=f.c2.indexOf(text.charAt(j));if(k<0)k=0;int[] row=f.d2[k];int v=row[0]+row[1]+row[2]+row[3]+pos+7+20;
                    if((i&2)!=0){draws+=2;digest=digest*31+v+1;digest=digest*31+v+1;}draws++;digest=digest*31+v;pos+=row[2]+f.w1;
                }
            }
            require(s.draws==draws&&s.digest==digest);
            if(i%1000==999){System.gc();Thread.sleep(50);}
        }
        s.closed=true;boolean nul=false,bounds=false,shortrow=false,altNull=false;
        try{f.draw(w,null,0,0,0);}catch(NullPointerException e){nul=true;}
        int[][] save=f.d2;f.d2=new int[][]{{1,2,3,4}};try{f.draw(w,"b",0,0,0);}catch(ArrayIndexOutOfBoundsException e){bounds=true;}
        f.d2=new int[][]{{1,2,3}};try{f.draw(w,"a",0,0,0);}catch(ArrayIndexOutOfBoundsException e){shortrow=true;}
        f.d2=save;try{f.draw(w,"a",0,0,0,null);}catch(NullPointerException e){altNull=true;}
        require(nul&&bounds&&shortrow&&altNull&&s.draws==draws&&s.digest==digest);
        FileOutputStream out=new FileOutputStream(args[1]+"/glyph.txt");out.write("PASS 8000\n".getBytes());out.close();
    }
}
