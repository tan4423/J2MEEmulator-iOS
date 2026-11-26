#ifndef JARBOX_NATIVE_PAINT_DIAG_H
#define JARBOX_NATIVE_PAINT_DIAG_H
#include <stdint.h>

// One sample in each block of 32 paints, varying its position to avoid
// locking to alternating animation phases. Sequence is per VM.
static inline int jarbox_native_paint_selected(uint64_t n) {
    uint64_t block=n>>5;
    block ^= block>>30; block *= UINT64_C(0xbf58476d1ce4e5b9);
    block ^= block>>27; block *= UINT64_C(0x94d049bb133111eb);
    block ^= block>>31;
    return (n&31u)==(block&31u);
}
// Pixel counters are requests, not proof that raster ran or array was valid.
static inline uint64_t jarbox_native_paint_pixels(int32_t w,int32_t h) {
    return w>0 && h>0 ? (uint64_t)w*(uint64_t)h : 0;
}
static inline uint64_t jarbox_native_paint_add(uint64_t a,uint64_t b) {
    return b>UINT64_MAX-a ? UINT64_MAX : a+b;
}
static inline int jarbox_native_paint_valid(uint64_t total,uint64_t draw,uint64_t lcd,uint64_t other) {
    return draw<=total && lcd<=total-draw && other<=total-draw-lcd;
}
#endif
