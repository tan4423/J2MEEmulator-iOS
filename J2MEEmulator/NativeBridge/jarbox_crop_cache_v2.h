#ifndef JARBOX_CROP_CACHE_V2_H
#define JARBOX_CROP_CACHE_V2_H
#include <stdint.h>
#include <stddef.h>

// Canvas paintLock owns all entries. A retained source identity is charged
// once, plus a conservative full stride*height charge for every crop.
// No shared mutable state or change to CG crop/draw operations.
enum { JARBOX_CROP_SLOTS=128, JARBOX_CROP_WAYS=4, JARBOX_CROP_SETS=32,
       JARBOX_CROP_BUDGET=1024*1024, JARBOX_CROP_OVERHEAD=256 };
typedef struct {
    CGImageRef image;
    size_t charge;
    unsigned users;
} JarBoxCropSource;
typedef struct {
    CGImageRef crop;
    int x,y,w,h;
    unsigned source;
    size_t charge;
} JarBoxCropEntry;
typedef struct {
    size_t bytes;
    JarBoxCropEntry entry[JARBOX_CROP_SLOTS];
    JarBoxCropSource sources[JARBOX_CROP_SLOTS];
    unsigned char next[JARBOX_CROP_SETS];
} JarBoxCropCache;

static inline unsigned jarbox_crop_set(CGImageRef source,int x,int y,int w,int h) {
    uint64_t k=(uint64_t)(uintptr_t)source >> 4;
    k ^= (uint64_t)(uint32_t)x * UINT64_C(0x9e3779b185ebca87);
    k ^= (uint64_t)(uint32_t)y * UINT64_C(0xc2b2ae3d27d4eb4f);
    k ^= (uint64_t)(uint32_t)w * UINT64_C(0x165667b19e3779f9);
    k ^= (uint64_t)(uint32_t)h * UINT64_C(0x85ebca77c2b2ae63);
    k ^= k >> 33; k *= UINT64_C(0xff51afd7ed558ccd); k ^= k >> 33;
    return (unsigned)k & (JARBOX_CROP_SETS-1);
}
static inline size_t jarbox_crop_cost(CGImageRef image) {
    size_t stride=CGImageGetBytesPerRow(image), height=CGImageGetHeight(image);
    if (!height || !stride || stride > JARBOX_CROP_BUDGET / height)
        return JARBOX_CROP_BUDGET+1;
    return stride*height;
}
static inline void jarbox_crop_remove(JarBoxCropCache *c,JarBoxCropEntry *e) {
    if (!e->crop) return;
    JarBoxCropSource *s=&c->sources[e->source];
    CGImageRelease(e->crop);
    c->bytes-=e->charge;
    *e=(JarBoxCropEntry){0};
    if (!--s->users) {
        CGImageRelease(s->image);
        c->bytes-=s->charge;
        *s=(JarBoxCropSource){0};
    }
}
static inline void jarbox_crop_clear(JarBoxCropCache *c) {
    for (unsigned i=0;i<JARBOX_CROP_SLOTS;i++) jarbox_crop_remove(c,&c->entry[i]);
    *c=(JarBoxCropCache){0};
}
static inline CGImageRef jarbox_crop_get(JarBoxCropCache *c,CGImageRef source,
                                         int x,int y,int w,int h,int *hit) {
    *hit=0;
    if (!c) return CGImageCreateWithImageInRect(source,CGRectMake(x,y,w,h));
    unsigned set=jarbox_crop_set(source,x,y,w,h), base=set*JARBOX_CROP_WAYS;
    unsigned victim=c->next[set], empty=JARBOX_CROP_WAYS;
    for (unsigned i=0;i<JARBOX_CROP_WAYS;i++) {
        JarBoxCropEntry *e=&c->entry[base+i];
        if (!e->crop) { if (empty==JARBOX_CROP_WAYS) empty=i; continue; }
        if (c->sources[e->source].image==source && e->x==x && e->y==y && e->w==w && e->h==h) {
            *hit=1;
            return CGImageRetain(e->crop);
        }
    }
    if (empty<JARBOX_CROP_WAYS) victim=empty;
    CGImageRef crop=CGImageCreateWithImageInRect(source,CGRectMake(x,y,w,h));
    if (!crop) return NULL;
    size_t sourceCost=jarbox_crop_cost(source), cropCost=jarbox_crop_cost(crop);
    const size_t budget=JARBOX_CROP_BUDGET-sizeof(*c);
    if (sourceCost>budget || cropCost>budget || cropCost+JARBOX_CROP_OVERHEAD>budget) return crop;
    size_t charge=cropCost+JARBOX_CROP_OVERHEAD;
    unsigned found=JARBOX_CROP_SLOTS, freeSlot=JARBOX_CROP_SLOTS;
    for (unsigned i=0;i<JARBOX_CROP_SLOTS;i++) {
        if (c->sources[i].image==source) { found=i; break; }
        if (!c->sources[i].users && freeSlot==JARBOX_CROP_SLOTS) freeSlot=i;
    }
    JarBoxCropEntry *e=&c->entry[base+victim];
    size_t remaining=c->bytes;
    if (e->crop) {
        remaining-=e->charge;
        JarBoxCropSource *old=&c->sources[e->source];
        if (old->users==1 && e->source!=found) {
            remaining-=old->charge;
            if (freeSlot==JARBOX_CROP_SLOTS) freeSlot=e->source;
        }
    }
    size_t extra=charge+(found==JARBOX_CROP_SLOTS?sourceCost:0);
    if (extra>budget || remaining>budget-extra ||
        (found==JARBOX_CROP_SLOTS && freeSlot==JARBOX_CROP_SLOTS)) return crop;
    // Reserve existing source before eviction, even if victim is its last user.
    unsigned id=found==JARBOX_CROP_SLOTS?freeSlot:found;
    if (found!=JARBOX_CROP_SLOTS) ++c->sources[id].users;
    jarbox_crop_remove(c,e);
    if (found==JARBOX_CROP_SLOTS) {
        c->sources[id]=(JarBoxCropSource){CGImageRetain(source),sourceCost,1};
        c->bytes+=sourceCost;
    }
    *e=(JarBoxCropEntry){CGImageRetain(crop),x,y,w,h,id,charge};
    c->bytes+=charge;
    c->next[set]=(unsigned char)((victim+1)%JARBOX_CROP_WAYS);
    return crop;
}
#endif
