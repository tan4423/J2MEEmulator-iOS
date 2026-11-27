#include <assert.h>
#include <stdio.h>
#include <stdint.h>
typedef struct {union{int64_t lvalue;uint64_t ulvalue;int32_t ivalue;uint32_t uivalue;};void *rvalue;} StackEntry;
#include "jarbox_render_island.h"
static unsigned cp(void *ctx,unsigned op,unsigned ix){
    (void)ctx;
    if(op==0xb6&&ix==1)return jri_shape(5,1);
    if(op==0xb2&&ix==2)return 1;
    if(op==0xb2&&ix==3)return 2;
    if(op==0xb6&&ix==4)return jri_shape(5,3);
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
    uint8_t image_code[]={0x2a,0xb2,0,3,0x03,0x04,0x05,0xb6,0,4,0xb1};
    p=jri_build(image_code,sizeof image_code,1,5,NULL,0,1,cp,NULL);
    assert(p&&p->count==1&&p->island[0].argc==5&&p->island[0].ref_kind==JRI_REF_STATIC&&p->island[0].ref_index==3);
    StackEntry a[24],b[24];int wrapper,graphics,image,old;
    for(unsigned i=0;i<24;++i){a[i].ulvalue=UINT64_C(0x123456789)+i;a[i].rvalue=&old;}
    memcpy(b,a,sizeof a);a[2].rvalue=&wrapper;a[3].rvalue=&image;a[7].rvalue=&graphics;a[8].rvalue=&image;
    jri_replay_wrapper_refs(b+2,p->island,&wrapper,&graphics,&image);
    assert(!memcmp(a,b,sizeof a));free(p);
    image_code[1]=0x01;image_code[2]=0x00;image_code[3]=0x00;
    assert(!jri_build(image_code,sizeof image_code,1,5,NULL,0,1,cp,NULL)); /* NOP is a boundary */
    uint8_t local_image[]={0x2a,0x2b,0x03,0x04,0x05,0xb6,0,4,0xb1};
    p=jri_build(local_image,sizeof local_image,2,5,NULL,0,1,cp,NULL);
    assert(p&&p->island[0].ref_kind==JRI_REF_LOCAL&&p->island[0].ref_index==1);free(p);
    local_image[1]=0x01;p=jri_build(local_image,sizeof local_image,1,5,NULL,0,1,cp,NULL);
    assert(p&&p->island[0].ref_kind==JRI_REF_NULL);free(p);
    /* A resolved invocation may have unrelated values below its arguments.
     * Refuse underflow and insufficient scratch room without writing any lane. */
    memcpy(b,a,sizeof a);
    for(unsigned argc=1;argc<=JRI_MAX_ARGS;++argc){
        for(unsigned base=0;base<=24;++base)for(unsigned sp=base;sp<=24;++sp){
            StackEntry *args=jri_call_args(b+sp,b+base,b+24,argc);
            int ok=sp-base>=argc&&24-sp>=argc+2;
            assert((args!=NULL)==ok);
            if(ok)assert(args==b+sp-argc);
            assert(!memcmp(a,b,sizeof a));
        }
    }
    assert(!jri_call_args(b+8,b,b+24,0));
    assert(!jri_call_args(b+8,b,b+24,JRI_MAX_ARGS+1));
    puts("render islands: exact typed arguments, branch/handler/unknown/fault refusal PASS");
}
