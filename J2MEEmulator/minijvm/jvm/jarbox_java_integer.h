#ifndef JARBOX_JAVA_INTEGER_H
#define JARBOX_JAVA_INTEGER_H

#include <stdint.h>
#include <string.h>

// Java integer arithmetic is modulo 2^32/2^64, not signed C overflow.
// Copy bit patterns instead of relying on an out-of-range signed cast.
// All supported MiniJVM targets use exact-width two's-complement types.
static inline int32_t jarbox_java_i32(uint32_t x) {
    int32_t v; memcpy(&v,&x,sizeof(v)); return v;
}
static inline int64_t jarbox_java_i64(uint64_t x) {
    int64_t v; memcpy(&v,&x,sizeof(v)); return v;
}
static inline int32_t jarbox_java_iadd(int32_t a,int32_t b) {return jarbox_java_i32((uint32_t)a+(uint32_t)b);}
static inline int32_t jarbox_java_isub(int32_t a,int32_t b) {return jarbox_java_i32((uint32_t)a-(uint32_t)b);}
static inline int32_t jarbox_java_imul(int32_t a,int32_t b) {return jarbox_java_i32((uint32_t)a*(uint32_t)b);}
static inline int64_t jarbox_java_ladd(int64_t a,int64_t b) {return jarbox_java_i64((uint64_t)a+(uint64_t)b);}
static inline int64_t jarbox_java_lsub(int64_t a,int64_t b) {return jarbox_java_i64((uint64_t)a-(uint64_t)b);}
static inline int64_t jarbox_java_lmul(int64_t a,int64_t b) {return jarbox_java_i64((uint64_t)a*(uint64_t)b);}
// Callers retain their existing zero-divisor exception path.
static inline int32_t jarbox_java_idiv(int32_t a,int32_t b) {return a==INT32_MIN&&b==-1?INT32_MIN:a/b;}
static inline int32_t jarbox_java_irem(int32_t a,int32_t b) {return a==INT32_MIN&&b==-1?0:a%b;}
static inline int64_t jarbox_java_ldiv(int64_t a,int64_t b) {return a==INT64_MIN&&b==-1?INT64_MIN:a/b;}
static inline int64_t jarbox_java_lrem(int64_t a,int64_t b) {return a==INT64_MIN&&b==-1?0:a%b;}
static inline int32_t jarbox_java_ishl(int32_t a,int32_t b) {return jarbox_java_i32((uint32_t)a<<((uint32_t)b&31u));}
static inline int64_t jarbox_java_lshl(int64_t a,int32_t b) {return jarbox_java_i64((uint64_t)a<<((uint32_t)b&63u));}
static inline int32_t jarbox_java_ishr(int32_t a,int32_t b) {
    uint32_t n=(uint32_t)b&31u, u=(uint32_t)a;
    return jarbox_java_i32(a<0?~(~u>>n):u>>n);
}
static inline int64_t jarbox_java_lshr(int64_t a,int32_t b) {
    uint32_t n=(uint32_t)b&63u; uint64_t u=(uint64_t)a;
    return jarbox_java_i64(a<0?~(~u>>n):u>>n);
}
#endif
