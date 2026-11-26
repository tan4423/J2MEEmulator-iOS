#include <stdint.h>
#include <assert.h>
#include <stdio.h>
typedef struct { union {int64_t lvalue; int32_t ivalue;}; void *ref; } LocalVarItem;
typedef struct {int64_t ctx,img; int32_t sx,sy,w,h,transform,x,y,anchor;uint64_t owner_key;} TreoRegionArgs;
#include "jarbox_region_slots.h"
static uint64_t rnd=1;
static uint64_t next(void){rnd=rnd*UINT64_C(6364136223846793005)+1;return rnd;}
int main(void){
    for(unsigned j=0;j<100000;j++){
        LocalVarItem v[12]={0};
        for(unsigned i=0;i<12;i++)v[i].lvalue=(int64_t)(next()>>1);
        v[9].ivalue=-(int32_t)(next()>>33);v[10].ivalue=INT32_MIN;
        uint64_t owner=next();TreoRegionArgs a=jarbox_region_args(v,owner);
        assert(a.ctx==v[0].lvalue&&a.img==v[2].lvalue&&a.sx==v[4].ivalue&&a.sy==v[5].ivalue);
        assert(a.w==v[6].ivalue&&a.h==v[7].ivalue&&a.transform==v[8].ivalue&&a.x==v[9].ivalue&&a.y==v[10].ivalue&&a.anchor==v[11].ivalue&&a.owner_key==owner);
    }
    puts("PASS 100000 native region slot layouts");
}
