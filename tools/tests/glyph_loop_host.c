#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
typedef struct {union{uint64_t u;int32_t i;};void *rvalue;} StackEntry;
#include "jarbox_glyph_loop.h"
typedef struct { unsigned n,len[512];int token[512]; } Table;
static void *row(void *p,unsigned i){Table *t=p;return i<t->n&&t->len[i]>=4?&t->token[i]:NULL;}
static uint32_t rng=0x7ae41d2bu;
static unsigned next(void){rng^=rng<<13;rng^=rng>>17;rng^=rng<<5;return rng;}
int main(void){
    unsigned yes=0,no=0;uint16_t text[512],alphabet[512];Table table;
    for(unsigned k=0;k<40000;++k){
        unsigned n=1+next()%128,a=next()%128;
        if(k%4==0)n=1+next()%3;
        table.n=k%5?128:next()%128;
        for(unsigned i=0;i<128;++i){alphabet[i]=(uint16_t)(next()%100);table.len[i]=k%3?4:next()%6;}
        for(unsigned i=0;i<n;++i)text[i]=(uint16_t)(next()%120);
        int good=1;void *last=NULL;
        for(unsigned i=0;i<n;++i){unsigned at=0;
            for(unsigned j=0;j<a;++j)if(alphabet[j]==text[i]){at=j;break;}
            last=row(&table,at);if(!last)good=0;
        }
        void *actual=(void *)(uintptr_t)1;
        int accepted=jbg_loop_preflight((JbgText){(const unsigned char *)text,n},(JbgText){(const unsigned char *)alphabet,a},row,&table,&actual);
        if(accepted){assert(good&&actual==last);++yes;}else{assert(actual==(void *)(uintptr_t)1);++no;}
        if(good&&n<4)assert(accepted);
        if(good&&table.n>=128&&k%3)assert(accepted);
    }
    StackEntry a[24],b[24];int x[6];for(unsigned i=0;i<24;++i){a[i].u=next();a[i].rvalue=&x[5];}
    memcpy(b,a,sizeof a);a[1].rvalue=&x[0];a[2].rvalue=&x[2];a[3].rvalue=&x[1];
    a[4].rvalue=a[5].rvalue=a[6].rvalue=&x[2];a[11].rvalue=&x[3];a[12].rvalue=&x[4];
    jbg_replay(b+1,&x[0],&x[1],&x[2],&x[3],&x[4]);assert(!memcmp(a,b,sizeof a));
    assert(yes>10000&&no>1000);
    printf("glyph loop preflight: %u accepted, %u refused; no false acceptance, reference replay PASS\n",yes,no);
}
