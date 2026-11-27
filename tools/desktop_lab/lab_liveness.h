#ifndef JARBOX_LAB_LIVENESS_H
#define JARBOX_LAB_LIVENESS_H
#include <stdint.h>
/* Stale reasons: 1 paint, 2 skill, 3 network call, 4 update call. */
enum { JLG_SIGNALS=4 };
typedef struct {uint64_t last[JLG_SIGNALS],seen[JLG_SIGNALS];} JlgState;
static inline void jlg_observe(JlgState *s,uint64_t now,const uint64_t v[JLG_SIGNALS]){
    for(unsigned i=0;i<JLG_SIGNALS;i++){
        if(v[i]>s->last[i])s->seen[i]=now;
        else if(v[i]<s->last[i])s->seen[i]=0;
        s->last[i]=v[i];
    }
}
static inline int jlg_stale(const JlgState *s,uint64_t now,uint64_t limit){
    for(unsigned i=0;i<JLG_SIGNALS;i++)
        if(!s->seen[i]||now<s->seen[i]||now-s->seen[i]>=limit)return (int)i+1;
    return 0;
}
#endif
