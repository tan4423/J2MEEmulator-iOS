public final class ArrayIndexOracle {
    private static int seed=1;
    private static int next(){seed=seed*1664525+1013904223;return seed;}
    private static void check(int x,int y,int w,int len){
        int idx=y*w+x;
        boolean ok=idx>=0 && idx<len;
        System.out.println((ok?1:0)+":"+(ok?idx:0));
    }
    public static void main(String[] args){
        int[] edge={Integer.MIN_VALUE,Integer.MIN_VALUE+1,-65536,-1,0,1,2,32768,65536,Integer.MAX_VALUE-1,Integer.MAX_VALUE};
        for(int x:edge)for(int y:edge)for(int w:edge)for(int l:edge)check(x,y,w,l);
        for(int i=0;i<200000;i++){
            int x=next(),y=next(),w=next(),l=next();
            if((i&1)!=0){x%=64;y%=64;w%=64;l=4096;}
            check(x,y,w,l);
        }
    }
}
