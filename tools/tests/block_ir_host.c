#include <assert.h>
#include <stdio.h>
#include <stdint.h>
#include <string.h>
typedef struct { union { int64_t lvalue;uint64_t ulvalue;int32_t ivalue;uint32_t uivalue; }; void *rvalue; } StackEntry;
#include "jarbox_block_ir.h"
/* Independent stack reference, using unsigned arithmetic for modulo Java. */
static uint64_t rng=UINT64_C(0xabc987ff1234);
static uint64_t random64(void){rng^=rng<<13;rng^=rng>>7;rng^=rng<<17;return rng;}
static unsigned reference(const uint8_t *code, unsigned n, StackEntry *s,StackEntry *l,unsigned sp) {
    unsigned pc=0;
    while(pc<n) {
        unsigned o=code[pc++];
        if(o>=2&&o<=8){s[sp++].ivalue=(int)o-3;continue;}
        if(o>=0x1a&&o<=0x1d){s[sp++].ivalue=l[o-0x1a].ivalue;continue;}
        if(o>=0x2a&&o<=0x2d){s[sp++].rvalue=l[o-0x2a].rvalue;continue;}
        if(o>=0x3b&&o<=0x3e){l[o-0x3b].ivalue=s[--sp].ivalue;continue;}
        if(o>=0x4b&&o<=0x4e){l[o-0x4b].rvalue=s[--sp].rvalue;continue;}
        if(o==0x16){s[sp].lvalue=l[code[pc++]].lvalue;sp+=2;continue;}
        if(o==0x37){sp-=2;l[code[pc++]].lvalue=s[sp].lvalue;continue;}
        if(o==0xc4){assert(code[pc++]==0x84);unsigned k=((unsigned)code[pc]<<8)|code[pc+1];pc+=2;uint16_t v=((unsigned)code[pc]<<8)|code[pc+1];pc+=2;l[k].uivalue+=(uint32_t)(int32_t)(int16_t)v;continue;}
        if(o==0x01){s[sp++].rvalue=NULL;continue;}
        if(o==0x11){uint16_t v=((unsigned)code[pc]<<8)|code[pc+1];pc+=2;s[sp++].ivalue=(int16_t)v;continue;}
        if(o==0x59){s[sp]=s[sp-1];sp++;continue;}
        if(o==0x5c){s[sp]=s[sp-2];s[sp+1]=s[sp-1];sp+=2;continue;}
        if(o==0x57){--sp;continue;}if(o==0x58){sp-=2;continue;}
        if(o==0x74){s[sp-1].uivalue=0u-s[sp-1].uivalue;continue;}
        if(o==0x75){s[sp-2].ulvalue=UINT64_C(0)-s[sp-2].ulvalue;continue;}
        if(o==0x91){s[sp-1].ivalue=(int8_t)s[sp-1].ivalue;continue;}
        if(o==0x92){s[sp-1].ivalue=(uint16_t)s[sp-1].ivalue;continue;}
        if(o==0x93){s[sp-1].ivalue=(int16_t)s[sp-1].ivalue;continue;}
        if(o==0x85){s[sp-1].lvalue=s[sp-1].ivalue;sp++;continue;}
        if(o==0x88){--sp;s[sp-1].ivalue=(int32_t)s[sp-1].lvalue;continue;}
        if(o==0x94){int64_t a=s[sp-4].lvalue,b=s[sp-2].lvalue;sp-=3;s[sp-1].ivalue=(a>b)-(a<b);continue;}
        if(o==0x79||o==0x7b||o==0x7d){unsigned b=s[--sp].uivalue&63u;uint64_t a=s[sp-2].ulvalue;if(o==0x79)a<<=b;else if(o==0x7b)a=(uint64_t)((int64_t)a>>b);else a>>=b;s[sp-2].ulvalue=a;continue;}
        if(o==0x61||o==0x65||o==0x69||o==0x7f||o==0x81||o==0x83){sp-=2;uint64_t a=s[sp-2].ulvalue,b=s[sp].ulvalue;switch(o){case 0x61:a+=b;break;case 0x65:a-=b;break;case 0x69:a*=b;break;case 0x7f:a&=b;break;case 0x81:a|=b;break;case 0x83:a^=b;break;}s[sp-2].ulvalue=a;continue;}
        uint32_t b=s[--sp].uivalue,a=s[sp-1].uivalue;
        switch(o){case 0x60:a+=b;break;case 0x64:a-=b;break;case 0x68:a*=b;break;case 0x78:a<<=(b&31u);break;case 0x7a:a=(uint32_t)((int32_t)a>>(b&31u));break;case 0x7c:a>>=(b&31u);break;case 0x7e:a&=b;break;case 0x80:a|=b;break;case 0x82:a^=b;break;default:assert(0);}
        s[sp-1].uivalue=a;
    }
    return sp;
}
int main(void){
    unsigned checked=0;static const uint8_t iops[]={0x60,0x64,0x68,0x78,0x7a,0x7c,0x7e,0x80,0x82};
    static const uint8_t lops[]={0x61,0x65,0x69,0x7f,0x81,0x83};
    static const uint8_t shifts[]={0x79,0x7b,0x7d};
    for(unsigned trial=0;trial<20000;++trial){
        uint8_t code[]={0x1a,0x1b,0,0x59,0x74,0x1c,0,0x3b,0x57,0x2a,0x4b,0x01,0x4c,0x16,4,0x16,6,0,0x75,0x1d,0,0x5c,0x37,4,0x58,0xc4,0x84,0,8,0x80,0,0x11,0xfe,0xdc,0x91,0x92,0x93,0x85,0x88,0x3d,0xb1};
        code[2]=iops[trial%9];code[6]=iops[(trial/9)%9];code[17]=lops[trial%6];code[20]=shifts[trial%3];
        JbiPlan *p=jbi_build(code,sizeof(code),12,32,NULL,0,1);assert(p&&p->spans>=1);
        StackEntry a[64],b[64],la[12],lb[12];
        for(unsigned i=0;i<64;++i){a[i].ulvalue=random64();a[i].rvalue=(i&1)?&a[0]:NULL;}
        for(unsigned i=0;i<12;++i){la[i].ulvalue=random64();la[i].rvalue=(i&1)?&a[1]:NULL;}
        memcpy(b,a,sizeof(a));memcpy(lb,la,sizeof(la));unsigned sp=16;
        for(unsigned j=0;j<p->spans;++j){const JbiSpan *s=p->span+j;assert(jbi_find(p,s->pc)==s&&sp>=s->need&&64-sp>=s->peak);unsigned expected=reference(code+s->pc,s->end-s->pc,a,la,sp);jbi_execute(p,s,b+sp,lb);sp=(unsigned)((int)sp+s->delta);assert(sp==expected);assert(!memcmp(a,b,sizeof(a))&&!memcmp(la,lb,sizeof(la)));checked++;}
        free(p);
    }
    /* branch and handler entries inside a pure sequence split it. */
    uint8_t cfg[]={0xa7,0,7,3,4,0x60,0x57,3,4,0x60,0x57,0xb1};
    JbiPlan *p=jbi_build(cfg,sizeof cfg,1,2,NULL,0,1);assert(p&&p->spans==2&&jbi_find(p,3)&&jbi_find(p,7));free(p);
    cfg[2]=2;assert(!jbi_build(cfg,sizeof cfg,1,2,NULL,0,1));cfg[2]=7;
    JbiHandler h={3,11,9};p=jbi_build(cfg,sizeof cfg,1,2,&h,1,1);assert(p&&p->spans==1&&!jbi_find(p,7));free(p);
    uint8_t bad[]={0x03,0x04,0x60,0x57,0xaa,0,0,0};assert(!jbi_build(bad,sizeof bad,0,2,NULL,0,1));
    uint8_t jsr[]={0x03,0x04,0x60,0x57,0xa8,0,0};assert(!jbi_build(jsr,sizeof jsr,0,2,NULL,0,1));
    uint8_t boundary[]={3,4,0x60,0x57,0x6c,3,4,0x60,0x57,0xb1};p=jbi_build(boundary,sizeof boundary,0,2,NULL,0,1);assert(p&&p->spans==2&&p->span[0].end==4&&p->span[1].pc==5);free(p);
    printf("block IR: %u exact stack/local span comparisons PASS\n",checked);
}
