#include <assert.h>
#include <stdio.h>
#include "jarbox_region_stage.h"
int main(void){
    JarBoxRegionStage a={0},b={0};
    unsigned positions[128]={0};
    for(uint64_t block=0;block<100000;block++){
        unsigned count=0;
        for(unsigned i=0;i<128;i++)if(jarbox_region_stage_selected(block*128+i)){
            ++count;++positions[i];
            jarbox_region_stage_record(&a,1,11,31,(int)(block&1));
        }
        assert(count==1);
    }
    for(unsigned i=0;i<128;i++)assert(positions[i]>0);
    assert(a.samples==100000 && a.hit_samples==50000 && a.hit_ns==500000 && a.miss_ns==500000 && a.draw_ns==2000000);
    jarbox_region_stage_record(&a,0,1,2,1);
    jarbox_region_stage_record(&a,3,2,4,0);
    jarbox_region_stage_record(&a,1,4,3,0);
    assert(a.invalid==3 && a.samples==100000 && !b.samples);
    puts("PASS 100000 region selection blocks, clock failure and scope isolation");
}
