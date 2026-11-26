#ifndef JARBOX_NINJA_CORE_POLICY_H
#define JARBOX_NINJA_CORE_POLICY_H
#include <stdint.h>
#include <string.h>

// Archive profiles are experimental eligibility, not proofs of all effects.
// One owner, one lifetime. No mutable global authorization or JAR rewriting.
typedef struct {
    uint64_t profile, armed, rejected, frames, faults;
    uint64_t scoped_native_draw_skips, scoped_vm_draw_skips;
} JarBoxNinjaCoreState;

static inline unsigned jarbox_ninja_core_profile(const unsigned char digest[32]) {
    static const unsigned char known[3][32] = {
        {0x96,0xf8,0x11,0xdc,0x13,0x17,0xec,0x41,0xba,0x01,0x95,0x33,0x50,0x43,0x6d,0xc8,0xf8,0x50,0x09,0x0c,0x30,0x18,0xa2,0x6b,0x4a,0xe3,0x5f,0x31,0x24,0xc2,0xe9,0x5d},
        {0x11,0xb1,0xd4,0xc1,0x1f,0x90,0x82,0xb9,0xd0,0x7b,0xc7,0xbd,0x92,0xa9,0xad,0x3a,0xba,0xd4,0x07,0x64,0x85,0x3e,0x23,0x68,0x6c,0xc8,0x66,0x86,0x86,0x9c,0x96,0x6c},
        {0x34,0x20,0xdf,0x8c,0xb9,0x1b,0xcc,0x33,0x85,0x22,0x30,0xd1,0xc6,0xf9,0x16,0x6a,0x99,0xd6,0xce,0x3f,0x2c,0x4a,0x33,0x2c,0xf1,0xba,0xd8,0x51,0xc3,0xf7,0xb2,0x76}
    };
    if (digest) for (unsigned i=0;i<3;i++) if (!memcmp(digest,known[i],32)) return i+1;
    return 0;
}
static inline void jarbox_ninja_core_arm(JarBoxNinjaCoreState *s, int requested) {
    if (!s) return;
    __atomic_store_n(&s->armed, requested && __atomic_load_n(&s->profile,__ATOMIC_ACQUIRE) &&
        !__atomic_load_n(&s->rejected,__ATOMIC_ACQUIRE),__ATOMIC_RELEASE);
}
static inline int jarbox_ninja_core_active(const JarBoxNinjaCoreState *s, int mode) {
    return s && mode==1 && __atomic_load_n(&s->armed,__ATOMIC_ACQUIRE) &&
        __atomic_load_n(&s->profile,__ATOMIC_ACQUIRE) &&
        !__atomic_load_n(&s->rejected,__ATOMIC_ACQUIRE);
}
// An unexpected dependency or exceptional paint is a sticky rejection for
// this owner. It cannot undo effects of the already executed frame.
static inline void jarbox_ninja_core_finish(JarBoxNinjaCoreState *s, unsigned reason) {
    if (!s) return;
    if (reason) {
        __atomic_fetch_or(&s->rejected,(uint64_t)reason,__ATOMIC_ACQ_REL);
        __atomic_store_n(&s->armed,0,__ATOMIC_RELEASE);
        __atomic_fetch_add(&s->faults,1,__ATOMIC_RELAXED);
    } else __atomic_fetch_add(&s->frames,1,__ATOMIC_RELAXED);
}
#endif
