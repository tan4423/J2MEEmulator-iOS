#include "jarbox_array_index.h"
#include <assert.h>
#include <inttypes.h>
#include <stdio.h>
static uint32_t seed=1;
static uint32_t next(void){seed=seed*1664525u+1013904223u;return seed;}
static int32_t signed_bits(uint32_t v){return v<=INT32_MAX?(int32_t)v:(int32_t)((int64_t)v-INT64_C(4294967296));}
static void check(int32_t x,int32_t y,int32_t w,int32_t len){
    uint32_t idx=UINT32_MAX;int ok=jarbox_array_index(x,y,w,len,&idx);
    assert(ok?(len>0 && idx<(uint32_t)len):idx==UINT32_MAX);
    printf("%d:%" PRIu32 "\n",ok,ok?idx:0);
}
int main(void){
    const int32_t edge[]={INT32_MIN,INT32_MIN+1,-65536,-1,0,1,2,32768,65536,INT32_MAX-1,INT32_MAX};
    for(unsigned x=0;x<11;x++)for(unsigned y=0;y<11;y++)for(unsigned w=0;w<11;w++)for(unsigned l=0;l<11;l++)check(edge[x],edge[y],edge[w],edge[l]);
    for(unsigned i=0;i<200000;i++){
        int32_t x=signed_bits(next()),y=signed_bits(next()),w=signed_bits(next()),l=signed_bits(next());
        if(i&1){x%=64;y%=64;w%=64;l=4096;}
        check(x,y,w,l);
    }
    return 0;
}
