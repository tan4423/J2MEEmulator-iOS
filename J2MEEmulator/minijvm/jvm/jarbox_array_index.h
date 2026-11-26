#ifndef JARBOX_ARRAY_INDEX_H
#define JARBOX_ARRAY_INDEX_H
#include <stdint.h>
// Java int multiplication/addition wrap modulo 2^32. A negative signed
// result has its top bit set, so it cannot be below any positive int length.
// Leave output untouched on fallback; do not implement Java exceptions here.
static inline int jarbox_array_index(int32_t x,int32_t y,int32_t width,int32_t length,uint32_t *out) {
    uint32_t bits=(uint32_t)y*(uint32_t)width+(uint32_t)x;
    if(length<=0 || bits>=(uint32_t)length) return 0;
    *out=bits;return 1;
}
#endif
