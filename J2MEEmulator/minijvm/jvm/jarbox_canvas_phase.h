#ifndef JARBOX_CANVAS_PHASE_H
#define JARBOX_CANVAS_PHASE_H
#include <stdint.h>
#include <limits.h>
// Thread-local, numeric owner identity only. A nested or malformed pair is
// excluded rather than charging the outer frame twice.
typedef struct {
    uint64_t owner, start, paint_start, paint_end;
    unsigned depth, active, invalid, stage;
} JarBoxCanvasPhaseScope;
typedef struct {uint64_t frames, pre_ns, paint_ns, post_ns;} JarBoxCanvasPhaseTotals;
typedef struct {
    unsigned lock;
    uint64_t invalid, busy;
    JarBoxCanvasPhaseTotals totals;
} JarBoxCanvasPhaseStats;
static inline void jarbox_canvas_phase_begin(JarBoxCanvasPhaseScope *s,uint64_t owner,int active,uint64_t now) {
    if (!owner || s->owner!=owner) *s=(JarBoxCanvasPhaseScope){0};
    if (!owner) return;
    if(s->depth) {if(s->depth<UINT_MAX)++s->depth;s->invalid=1;return;}
    *s=(JarBoxCanvasPhaseScope){.owner=owner,.start=now,.depth=1,.active=active!=0};
}
static inline void jarbox_canvas_phase_point(JarBoxCanvasPhaseScope *s,uint64_t owner,unsigned stage,uint64_t now) {
    if(!s->active || s->owner!=owner || s->depth!=1 || s->invalid)return;
    if(stage!=s->stage+1 || stage>2 || !now || now<(stage==1?s->start:s->paint_start)){s->invalid=1;return;}
    if(stage==1)s->paint_start=now;else s->paint_end=now;
    s->stage=stage;
}
static inline int jarbox_canvas_phase_try(JarBoxCanvasPhaseStats *t) {
    unsigned expected=0;
    return __atomic_compare_exchange_n(&t->lock,&expected,1,0,__ATOMIC_ACQUIRE,__ATOMIC_RELAXED);
}
static inline void jarbox_canvas_phase_unlock(JarBoxCanvasPhaseStats *t) {__atomic_store_n(&t->lock,0,__ATOMIC_RELEASE);}
static inline int jarbox_canvas_phase_end(JarBoxCanvasPhaseScope *s,JarBoxCanvasPhaseStats *t,uint64_t owner,int active,uint64_t now) {
    if(!owner || owner!=s->owner){*s=(JarBoxCanvasPhaseScope){0};return 0;}
    if(!s->depth)return 0;
    if(--s->depth)return 0;
    JarBoxCanvasPhaseScope c=*s;*s=(JarBoxCanvasPhaseScope){0};
    if(!c.active || !t)return 0;
    if(!active || c.invalid || c.stage!=2 || !c.start || now<c.paint_end){__atomic_fetch_add(&t->invalid,1,__ATOMIC_RELAXED);return 0;}
    if(!jarbox_canvas_phase_try(t)){__atomic_fetch_add(&t->busy,1,__ATOMIC_RELAXED);return 0;}
    ++t->totals.frames;t->totals.pre_ns+=c.paint_start-c.start;
    t->totals.paint_ns+=c.paint_end-c.paint_start;t->totals.post_ns+=now-c.paint_end;
    jarbox_canvas_phase_unlock(t);return 1;
}
static inline int jarbox_canvas_phase_snapshot(JarBoxCanvasPhaseStats *t,JarBoxCanvasPhaseTotals *out) {
    *out=(JarBoxCanvasPhaseTotals){0};if(!jarbox_canvas_phase_try(t))return 0;
    *out=t->totals;jarbox_canvas_phase_unlock(t);return 1;
}
#endif
