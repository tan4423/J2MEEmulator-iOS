#include "lab_liveness.h"
#include <assert.h>
#include <stdio.h>
int main(void){
    JlgState s={0};
    uint64_t v[JLG_SIGNALS]={0};
    assert(jlg_stale(&s,1,8)==1);
    for(unsigned i=0;i<JLG_SIGNALS;i++)v[i]=1;
    jlg_observe(&s,10,v);
    assert(!jlg_stale(&s,17,8));
    for(unsigned i=0;i<JLG_SIGNALS;i++){
        JlgState trial=s;
        uint64_t w[JLG_SIGNALS]={2,2,2,2};w[i]=1;
        jlg_observe(&trial,18,w);
        assert(jlg_stale(&trial,18,8)==(int)i+1);
        w[i]=2;jlg_observe(&trial,19,w);
        assert(!jlg_stale(&trial,19,8));
    }
    assert(jlg_stale(&s,9,8)==1);
    v[1]=0;jlg_observe(&s,11,v);
    assert(jlg_stale(&s,11,8)==2);
    puts("LAB_LIVENESS_GUARD_PASS");
    return 0;
}
