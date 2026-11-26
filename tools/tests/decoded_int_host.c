#include <assert.h>
#include <stdio.h>
#include <stdint.h>
#include "jarbox_decoded_int.h"
static uint32_t seed=1;
static uint32_t rnd(void){return seed=seed*1664525u+1013904223u;}
static uint32_t bits(int32_t x){uint32_t r;memcpy(&r,&x,4);return r;}
static uint32_t reference(unsigned op,uint32_t a,uint32_t b){
    unsigned n=b%32;switch(op){case 0x60:return a+b;case 0x64:return a-b;case 0x68:return a*b;
    case 0x7e:return a&b;case 0x80:return a|b;case 0x82:return a^b;case 0x78:return a<<n;
    case 0x7c:return a>>n;case 0x7a:{uint32_t v=a;while(n--)v=(v>>1)|(v&0x80000000u);return v;}}
    assert(0);return 0;
}
int main(void){
    const unsigned ops[]={0x60,0x64,0x68,0x7e,0x80,0x82,0x78,0x7a,0x7c};
    for(unsigned i=0;i<100000;i++){
        uint32_t a[4]={rnd(),rnd(),rnd(),rnd()};unsigned op=ops[i%9],op2=ops[(i/9)%9];
        uint8_t code[]={0x1a,0x1b,op,0x15,2,op2,0x74,0xac};
        uint64_t p=jarbox_decoded_int_build(code,sizeof(code),"(III)I",3,2,0);
        assert(p&&bits(jarbox_decoded_int_eval(p,a))==0u-reference(op2,reference(op,a[0],a[1]),a[2]));
        unsigned v=rnd()&65535u;uint8_t imm[]={0x11,v>>8,v,0x1a,op,0xac};
        p=jarbox_decoded_int_build(imm,sizeof(imm),"(I)I",1,2,0);
        assert(p&&bits(jarbox_decoded_int_eval(p,a))==reference(op,v>=32768?v-65536u:v,a[0]));
        uint8_t small[]={0x10,v,0xac};p=jarbox_decoded_int_build(small,sizeof(small),"()I",0,1,0);
        v&=255;assert(p&&bits(jarbox_decoded_int_eval(p,a))==(v>=128?v-256u:v));
        uint8_t random[32];for(unsigned j=0;j<sizeof(random);j++)random[j]=(uint8_t)(rnd()>>24);
        p=jarbox_decoded_int_build(random,1+(rnd()%32),"(IIII)I",4,8,0);
        if(p)(void)jarbox_decoded_int_eval(p,a);
    }
    uint8_t good[]={0x1a,0x1b,0x60,0xac};
    assert(!jarbox_decoded_int_build(good,4,"(II)I",2,1,0));
    assert(!jarbox_decoded_int_build(good,4,"(II)I",2,2,1));
    assert(!jarbox_decoded_int_build(good,4,"(IJ)I",2,2,0));
    assert(!jarbox_decoded_int_build(good,4,"(II)J",2,2,0));
    assert(!jarbox_decoded_int_build(good,3,"(II)I",2,2,0));
    for(unsigned op=0;op<256;op++) {uint8_t c[]={0x1a,0x1b,op,0xac};uint64_t p=jarbox_decoded_int_build(c,4,"(II)I",2,2,0);int ok=0;for(unsigned k=0;k<9;k++)ok|=op==ops[k];assert(!!p==ok);}
    uint8_t longcode[]={0x11,1,2,0x11,3,4,0x60,0x11,5,6,0x60,0xac};assert(!jarbox_decoded_int_build(longcode,sizeof(longcode),"()I",0,2,0));
    puts("100000 decoded expression batches PASS");
}
