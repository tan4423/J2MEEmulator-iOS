#ifndef JARBOX_CORE_ABA_H
#define JARBOX_CORE_ABA_H
#include <stdint.h>
// Per-park schedule on a single monotonic clock. No timers, no catch-up.
// 0 inactive, 1/2 A1 warm/measure, 3/4 B warm/measure,
// 5/6 A2 warm/measure, 7 finished (full raster).
static inline unsigned jarbox_core_aba_phase(uint64_t start,uint64_t now) {
    if (!start || now<start) return 0;
    uint64_t seconds=(now-start)/UINT64_C(1000000000);
    if (seconds>=225) return 7;
    return (unsigned)(seconds/75)*2+1+(seconds%75>=15);
}
static inline int jarbox_core_aba_sink(unsigned phase) {
    return phase==3 || phase==4;
}
#endif
