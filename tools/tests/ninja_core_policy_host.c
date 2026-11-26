#include <assert.h>
#include <stdio.h>
#include "jarbox_ninja_core_policy.h"
int main(int argc,char **argv) {
    assert(argc==5);
    for(int i=1;i<argc;i++) {
        unsigned char d[32];
        assert(strlen(argv[i])==64);
        for(unsigned j=0;j<32;j++){unsigned x;assert(sscanf(argv[i]+j*2,"%2x",&x)==1);d[j]=(unsigned char)x;}
        assert(jarbox_ninja_core_profile(d)==(i<4?(unsigned)i:0));
        if(i<4)for(unsigned j=0;j<32;j++){d[j]^=1;assert(jarbox_ninja_core_profile(d)==0);d[j]^=1;}
    }
    JarBoxNinjaCoreState a={.profile=1},b={.profile=2},unknown={0};
    assert(!jarbox_ninja_core_active(&a,1));
    jarbox_ninja_core_arm(&unknown,1);assert(!jarbox_ninja_core_active(&unknown,1));
    jarbox_ninja_core_arm(&a,1);assert(jarbox_ninja_core_active(&a,1));assert(!jarbox_ninja_core_active(&b,1));
    for(int i=0;i<100000;i++){
        assert(!jarbox_ninja_core_active(&a,0)&&!jarbox_ninja_core_active(&a,8));
        jarbox_ninja_core_finish(&a,0);
    }
    assert(a.frames==100000 && b.frames==0);
    jarbox_ninja_core_arm(&a,0);assert(!jarbox_ninja_core_active(&a,1));
    jarbox_ninja_core_arm(&a,1);jarbox_ninja_core_finish(&a,1);assert(a.rejected==1 && a.faults==1);
    jarbox_ninja_core_finish(&a,2);assert(a.rejected==3 && a.faults==2);
    for(int i=0;i<100000;i++){jarbox_ninja_core_arm(&a,1);assert(!jarbox_ninja_core_active(&a,1));}
    jarbox_ninja_core_arm(&b,1);assert(jarbox_ninja_core_active(&b,1));
    assert(!jarbox_ninja_core_active(NULL,1));
    puts("PASS policy, owner isolation, exact hashes, sticky fallback");
}
