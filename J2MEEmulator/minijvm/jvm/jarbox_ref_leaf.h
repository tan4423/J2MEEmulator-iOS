#ifndef JARBOX_REF_LEAF_H
#define JARBOX_REF_LEAF_H
#include <stdint.h>

/* Original class-file bytes, before quickening. Low 16 bits = field CP
 * index; bit 16 = lazy initialization branch exists. A zero match is
 * always the ordinary interpreter. Only the already-nonnull branch of
 * the lazy getter can be accelerated; the cold branch is never replaced. */
static inline uint16_t jarbox_ref_leaf_u16(const uint8_t *p) {
    return (uint16_t)(((uint16_t)p[0] << 8) | p[1]);
}
static inline uint32_t jarbox_ref_leaf_match(const uint8_t *c, int n,
        const char *desc, int locals, int stack, int handlers) {
    if (!c || !desc || locals || handlers || stack < 1 || n < 4 ||
        desc[0] != '(' || desc[1] != ')' ||
        (desc[2] != 'L' && desc[2] != '[') || c[0] != 0xb2) return 0;
    uint16_t field = jarbox_ref_leaf_u16(c+1);
    if (!field) return 0;
    if (n == 4 && c[3] == 0xb0) return field;
    if (stack < 2 || (n != 20 && n != 22 && n != 24) ||
        c[3] != 0xc7 || c[6] != 0xbb || c[9] != 0x59 || c[10] != 0xb7)
        return 0;
    /* getstatic; ifnonnull L; new; dup; invokespecial;
     * [dup]; putstatic; [areturn or goto R]; L: getstatic; R: areturn */
    int put = n == 20 ? 13 : 14;
    int load = n == 20 ? 16 : n == 22 ? 18 : 20;
    if (jarbox_ref_leaf_u16(c+4) != load-3 ||
        (n != 20 && c[13] != 0x59) ||
        c[put] != 0xb3 || jarbox_ref_leaf_u16(c+put+1) != field ||
        c[load] != 0xb2 || jarbox_ref_leaf_u16(c+load+1) != field ||
        c[load+3] != 0xb0) return 0;
    if (n == 22 && c[17] != 0xb0) return 0;
    if (n == 24 && (c[17] != 0xa7 || jarbox_ref_leaf_u16(c+18) != 6)) return 0;
    return UINT32_C(0x10000) | field;
}
#endif
