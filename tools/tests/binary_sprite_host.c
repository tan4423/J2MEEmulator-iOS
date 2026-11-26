#include "jarbox_binary_sprite.h"
#include <assert.h>
#include <stdio.h>
static uint32_t seed=1;
static uint32_t next(void){seed=seed*1664525u+1013904223u;return seed;}
int main(void){
    uint32_t src[9*7],a[13*11],b[13*11];JarBoxBinaryRect p;
    for(unsigned n=0;n<100000;n++) {
        unsigned kind=2+n%3;
        for(unsigned i=0;i<63;i++){uint32_t v=next();src[i]=kind==JB_BIN_CLEAR || (kind==JB_BIN_MIXED && (v&1))?0:v|0xff000000u;}
        unsigned actual=jarbox_binary_kind(src,8,7,9);assert(actual==kind);
        for(unsigned i=0;i<143;i++)a[i]=b[i]=next();
        int x=(int)(next()%24)-12,y=(int)(next()%20)-10;
        int sx=next()%8,sy=next()%7,w=1+next()%(8-sx),h=1+next()%(7-sy);
        int l=next()%13,t=next()%11,r=l+next()%(14-l),bottom=t+next()%(12-t);
        assert(jarbox_binary_rect(&p,x,y,sx,sy,w,h,8,7,13,11,l,t,r,bottom));
        if(p.w && p.h)jarbox_binary_blit(a+p.y*13+p.x,13,src+p.sy*9+p.sx,9,p.w,p.h,kind);
        for(int j=0;j<h;j++)for(int i=0;i<w;i++){
            int dx=x+i,dy=y+j;if(dx<l||dx>=r||dy<t||dy>=bottom)continue;
            uint32_t v=src[(sy+j)*9+sx+i];if(v>>24)b[dy*13+dx]=v;
        }
        assert(!memcmp(a,b,sizeof a));
    }
    src[0]=0x7f010203;assert(jarbox_binary_kind(src,8,7,9)==JB_BIN_REJECT);
    src[0]=1;assert(jarbox_binary_kind(src,8,7,9)==JB_BIN_REJECT);
    assert(jarbox_binary_kind(src,8,7,SIZE_MAX)==JB_BIN_REJECT);
    assert(!jarbox_binary_rect(&p,INT64_MAX,0,0,0,1,1,8,7,13,11,0,0,13,11));
    assert(!jarbox_binary_rect(&p,0,0,7,0,2,1,8,7,13,11,0,0,13,11));
    assert(!jarbox_binary_rect(&p,0,0,0,0,1,1,8,7,13,11,-1,0,13,11));
    puts("PASS 100000 binary sprites, clip/offset/stride and rejection cases");
}
