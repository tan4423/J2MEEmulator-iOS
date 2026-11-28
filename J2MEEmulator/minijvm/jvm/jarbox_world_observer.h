#ifndef JARBOX_WORLD_OBSERVER_H
#define JARBOX_WORLD_OBSERVER_H
#include <stdint.h>
/* Exact primitive field writes, no Java object or pointer retained. A single
 * atomic word publishes map, zone, validity and a transition epoch together. */
#define JWO_MAP_KNOWN (UINT64_C(1)<<24)
#define JWO_ZONE_KNOWN (UINT64_C(1)<<25)
#define JWO_EPOCH_SHIFT 26
#define JWO_VALUE_MASK ((UINT64_C(1)<<JWO_EPOCH_SHIFT)-1)
static inline uint64_t jwo_update(uint64_t old,int zone,unsigned value){
    uint64_t mask=zone?(UINT64_C(255)<<16):UINT64_C(65535);
    uint64_t bits=zone?(((uint64_t)value&255)<<16)|JWO_ZONE_KNOWN:((uint64_t)value&65535)|JWO_MAP_KNOWN;
    uint64_t low=(old&JWO_VALUE_MASK&~mask)|bits;
    if(low==(old&JWO_VALUE_MASK))return old;
    uint64_t epoch=old>>JWO_EPOCH_SHIFT;
    if(epoch<(UINT64_MAX>>JWO_EPOCH_SHIFT))++epoch;
    return (epoch<<JWO_EPOCH_SHIFT)|low;
}
static inline int jwo_map(uint64_t s){return s&JWO_MAP_KNOWN?(int)(int16_t)(uint16_t)s:-1;}
static inline int jwo_zone(uint64_t s){return s&JWO_ZONE_KNOWN?(int)((s>>16)&255):-1;}
static inline uint64_t jwo_epoch(uint64_t s){return s>>JWO_EPOCH_SHIFT;}
#endif
