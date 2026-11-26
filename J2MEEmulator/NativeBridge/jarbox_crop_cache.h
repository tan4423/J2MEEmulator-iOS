#ifndef JARBOX_CROP_CACHE_H
#define JARBOX_CROP_CACHE_H
#include <stdint.h>
#include <stddef.h>

// Canvas paintLock protects this cache. The caller must retain the immutable
// source during the call. Entries retain both identities, preventing ABA.
// The charge deliberately counts the whole source backing per entry as well
// as the crop backing, even when Core Graphics shares it.
enum { JARBOX_CROP_SLOTS=64, JARBOX_CROP_BUDGET=1024*1024, JARBOX_CROP_OVERHEAD=256 };
typedef struct {
    CGImageRef source, crop;
    int x,y,w,h;
    size_t charge;
} JarBoxCropEntry;
typedef struct {
    size_t bytes;
    JarBoxCropEntry entry[JARBOX_CROP_SLOTS];
} JarBoxCropCache;

static inline unsigned jarbox_crop_index(CGImageRef source,int x,int y,int w,int h) {
    uint64_t k=(uint64_t)(uintptr_t)source >> 4;
    k ^= (uint64_t)(uint32_t)x * UINT64_C(0x9e3779b185ebca87);
    k ^= (uint64_t)(uint32_t)y * UINT64_C(0xc2b2ae3d27d4eb4f);
    k ^= (uint64_t)(uint32_t)w * UINT64_C(0x165667b19e3779f9);
    k ^= (uint64_t)(uint32_t)h * UINT64_C(0x85ebca77c2b2ae63);
    k ^= k >> 33; k *= UINT64_C(0xff51afd7ed558ccd); k ^= k >> 33;
    return (unsigned)k & (JARBOX_CROP_SLOTS-1);
}
static inline size_t jarbox_crop_cost(CGImageRef image) {
    size_t stride=CGImageGetBytesPerRow(image), height=CGImageGetHeight(image);
    if (!height || !stride || stride > JARBOX_CROP_BUDGET / height)
        return JARBOX_CROP_BUDGET+1;
    return stride*height;
}
static inline void jarbox_crop_clear(JarBoxCropCache *c) {
    for (unsigned i=0;i<JARBOX_CROP_SLOTS;i++) {
        JarBoxCropEntry *e=&c->entry[i];
        if (e->crop) {
            CGImageRelease(e->crop);
            CGImageRelease(e->source);
            *e=(JarBoxCropEntry){0};
        }
    }
    c->bytes=0;
}
// Exactly the old crop operation on a miss, including allocation failure.
// Returns an owned result, with or without a cache.
static inline CGImageRef jarbox_crop_get(JarBoxCropCache *c,CGImageRef source,
                                         int x,int y,int w,int h,int *hit) {
    *hit=0;
    JarBoxCropEntry *e=c ? &c->entry[jarbox_crop_index(source,x,y,w,h)] : NULL;
    if (e && e->crop && e->source==source && e->x==x && e->y==y && e->w==w && e->h==h) {
        *hit=1;
        return CGImageRetain(e->crop);
    }
    CGImageRef crop=CGImageCreateWithImageInRect(source,CGRectMake(x,y,w,h));
    if (!crop || !e) return crop;
    size_t a=jarbox_crop_cost(source), b=jarbox_crop_cost(crop);
    size_t charge=a+b+JARBOX_CROP_OVERHEAD;
    if (charge > JARBOX_CROP_BUDGET-sizeof(*c) ||
        c->bytes-e->charge > JARBOX_CROP_BUDGET-sizeof(*c)-charge)
        return crop;
    // A failed creation or insufficient budget leaves the old entry intact.
    if (e->crop) {
        CGImageRelease(e->crop);
        CGImageRelease(e->source);
        c->bytes-=e->charge;
    }
    *e=(JarBoxCropEntry){CGImageRetain(source),CGImageRetain(crop),x,y,w,h,charge};
    c->bytes+=charge;
    return crop;
}
#endif
