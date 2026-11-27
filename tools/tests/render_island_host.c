#include <assert.h>
#include <stdio.h>
#include <stdint.h>
typedef struct {union{int64_t lvalue;uint64_t ulvalue;int32_t ivalue;uint32_t uivalue;};void *rvalue;} StackEntry;
#include "jarbox_render_island.h"
static unsigned cp(void *ctx,unsigned op,unsigned ix){
    (void)ctx;
    if(op==0xb6&&ix==1)return jri_shape(5,1);
    if(op==0xb2&&ix==2)return 1;
    return 0;
}
int main(void){
    uint8_t code[]={0x2a,0x1b,0x04,0x60,0xb2,0,2,0x05,0x06,0xb6,0,1,0xb1};
    JriPlan *p=jri_build(code,sizeof code,2,5,NULL,0,1,cp,NULL);
    assert(p&&p->count==1&&p->island[0].pc==0&&p->island[0].end==12&&
           p->island[0].steps==8&&p->island[0].nreads==1&&p->island[0].reads[0]==2);
    free(p);
    code[3]=0x6c;assert(!jri_build(code,sizeof code,2,5,NULL,0,1,cp,NULL));code[3]=0x60;
    JbiHandler h={0,12,8};assert(!jri_build(code,sizeof code,2,5,&h,1,1,cp,NULL));
    uint8_t branch[]={0xa7,0,4,0x2a,0x03,0x04,0x05,0x06,0xb6,0,1,0xb1};
    assert(!jri_build(branch,sizeof branch,1,5,NULL,0,1,cp,NULL));
    branch[2]=3;p=jri_build(branch,sizeof branch,1,5,NULL,0,1,cp,NULL);assert(p&&p->island[0].pc==3);free(p);
    code[11]=9;assert(!jri_build(code,sizeof code,2,5,NULL,0,1,cp,NULL));code[11]=1;
    code[8]=0x2a;assert(!jri_build(code,sizeof code,2,5,NULL,0,1,cp,NULL));code[8]=6;
    for(unsigned n=0;n<sizeof code;++n){p=jri_build(code,n,2,5,NULL,0,1,cp,NULL);assert(!p);}
    puts("render islands: exact typed arguments, branch/handler/unknown/fault refusal PASS");
}
