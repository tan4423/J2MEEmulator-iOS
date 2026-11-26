#ifndef JARBOX_REGION_STAGE_H
#define JARBOX_REGION_STAGE_H
#include <stdint.h>
typedef struct {
    uint64_t seen, samples, hit_samples, hit_ns, miss_ns, draw_ns, invalid;
} JarBoxRegionStage;
// Exactly one call per block of 128, with a rotating offset. Per Canvas.
static inline int jarbox_region_stage_selected(uint64_t n) {
    return (n&127u)==(((n>>7)*67u)&127u);
}
static inline void jarbox_region_stage_record(JarBoxRegionStage *s,
        uint64_t start,uint64_t middle,uint64_t end,int hit) {
    if (!start || middle<start || end<middle) { ++s->invalid; return; }
    ++s->samples;
    if (hit) { ++s->hit_samples; s->hit_ns+=middle-start; }
    else s->miss_ns+=middle-start;
    s->draw_ns+=end-middle;
}
#endif
