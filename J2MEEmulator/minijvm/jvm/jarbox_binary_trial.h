#ifndef JARBOX_BINARY_TRIAL_H
#define JARBOX_BINARY_TRIAL_H
#include "jarbox_core_aba.h"
#if defined(TREO_BINARY_ABA) && TREO_BINARY_ABA
#if !defined(TREO_BINARY_SPRITE_EXPERIMENT) || !TREO_BINARY_SPRITE_EXPERIMENT
#error Binary trial requires actual sprite backend
#endif
#if defined(TREO_CORE_ABA) && TREO_CORE_ABA
#error Binary trial cannot be combined with scoped raster elision
#endif
#endif
// Numeric identities only. Nested begin replaces admission; any end clears.
typedef struct { uint64_t owner; int64_t canvas; } JarBoxBinaryTrialScope;
static inline void jarbox_binary_trial_begin(JarBoxBinaryTrialScope *s,
        uint64_t owner,int64_t canvas,int mode,int headless,uint64_t epoch,uint64_t now) {
    *s=(JarBoxBinaryTrialScope){0};
    if (owner && canvas && mode==1 && !headless &&
        jarbox_core_aba_sink(jarbox_core_aba_phase(epoch,now))) {
        s->owner=owner; s->canvas=canvas;
    }
}
static inline void jarbox_binary_trial_end(JarBoxBinaryTrialScope *s) {
    *s=(JarBoxBinaryTrialScope){0};
}
static inline int jarbox_binary_trial_allowed(const JarBoxBinaryTrialScope *s,
        uint64_t owner,int64_t canvas) {
    return owner && canvas && s->owner==owner && s->canvas==canvas;
}
#endif
