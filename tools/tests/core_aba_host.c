#include "jarbox_core_aba.h"
#include <assert.h>
#include <stdio.h>
int main(void) {
    const uint64_t s=UINT64_C(1000000000000), n=UINT64_C(1000000000);
    assert(!jarbox_core_aba_phase(0,s));
    assert(!jarbox_core_aba_phase(s,s-1));
    for (unsigned ms=0;ms<240000;ms++) {
        unsigned p=jarbox_core_aba_phase(s,s+(uint64_t)ms*1000000);
        unsigned expected=ms<15000?1:ms<75000?2:ms<90000?3:ms<150000?4:ms<165000?5:ms<225000?6:7;
        assert(p==expected);
        assert(jarbox_core_aba_sink(p)==(ms>=75000 && ms<150000));
    }
    assert(jarbox_core_aba_phase(s,UINT64_MAX)==7);
    assert(jarbox_core_aba_phase(s,s+75*n-1)==2);
    assert(jarbox_core_aba_phase(s,s+75*n)==3);
    assert(jarbox_core_aba_phase(s,s+150*n-1)==4);
    assert(jarbox_core_aba_phase(s,s+150*n)==5);
    // Independent park epochs: B on one owner does not enable B on another.
    assert(jarbox_core_aba_sink(jarbox_core_aba_phase(s,s+100*n)));
    assert(!jarbox_core_aba_sink(jarbox_core_aba_phase(s+90*n,s+100*n)));
    assert(!jarbox_core_aba_sink(jarbox_core_aba_phase(0,s+100*n)));
    puts("PASS 240000 schedule checks, boundaries, inactive and independent epochs");
}
