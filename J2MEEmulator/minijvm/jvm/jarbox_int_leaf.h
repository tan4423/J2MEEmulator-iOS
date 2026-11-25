#ifndef JARBOX_INT_LEAF_H
#define JARBOX_INT_LEAF_H

#include <stdint.h>
#include <string.h>

// Match ORIGINAL class-file bytes (big-endian branch operands), before
// quickening or byte-order conversion. These are exact, terminating primitive
// expressions; no heap reads, calls, side effects or possible Java exception.
enum {
    JARBOX_LEAF_NONE = 0, JARBOX_LEAF_ABS, JARBOX_LEAF_IDENTITY,
    JARBOX_LEAF_NEGATE, JARBOX_LEAF_ADD, JARBOX_LEAF_SUB, JARBOX_LEAF_MUL,
    JARBOX_LEAF_AND, JARBOX_LEAF_OR, JARBOX_LEAF_XOR,
    JARBOX_LEAF_CONST_M1 = 16, JARBOX_LEAF_CONST_5 = 22
};

static inline uint8_t jarbox_int_leaf_match(const uint8_t *code, int length,
        const char *desc, int locals, int max_stack, int handlers) {
    if (!code || !desc || handlers || length < 2 || length > 11) return 0;
    if (locals == 1 && max_stack >= 1 && !strcmp(desc, "(I)I")) {
        // iload_0; ifle +5; iload_0; ireturn; iload_0; ineg; ireturn
        static const uint8_t abs_a[] = {0x1a,0x9e,0,5,0x1a,0xac,0x1a,0x74,0xac};
        // Equivalent forward goto variant used by several obfuscated mods.
        static const uint8_t abs_b[] = {0x1a,0x9e,0,7,0x1a,0xa7,0,5,0x1a,0x74,0xac};
        if ((length == (int)sizeof(abs_a) && !memcmp(code,abs_a,sizeof(abs_a))) ||
            (length == (int)sizeof(abs_b) && !memcmp(code,abs_b,sizeof(abs_b)))) return JARBOX_LEAF_ABS;
        if (length == 2 && code[0] == 0x1a && code[1] == 0xac) return JARBOX_LEAF_IDENTITY;
        if (length == 3 && code[0] == 0x1a && code[1] == 0x74 && code[2] == 0xac) return JARBOX_LEAF_NEGATE;
    }
    if (locals == 2 && max_stack >= 2 && !strcmp(desc, "(II)I") &&
        length == 4 && code[0] == 0x1a && code[1] == 0x1b && code[3] == 0xac) {
        switch (code[2]) {
            case 0x60: return JARBOX_LEAF_ADD;
            case 0x64: return JARBOX_LEAF_SUB;
            case 0x68: return JARBOX_LEAF_MUL;
            case 0x7e: return JARBOX_LEAF_AND;
            case 0x80: return JARBOX_LEAF_OR;
            case 0x82: return JARBOX_LEAF_XOR;
        }
    }
    if (locals == 0 && max_stack >= 1 && length == 2 && code[1] == 0xac &&
        code[0] >= 2 && code[0] <= 8 &&
        (!strcmp(desc, "()I") || (!strcmp(desc, "()Z") && (code[0] == 3 || code[0] == 4))))
        return (uint8_t)(JARBOX_LEAF_CONST_M1 + code[0] - 2);
    return JARBOX_LEAF_NONE;
}

// Java int arithmetic wraps modulo 2^32, including abs(Integer.MIN_VALUE).
// Use unsigned operations rather than signed-overflow C expressions.
static inline int32_t jarbox_int_leaf_eval(uint8_t kind, int32_t a, int32_t b) {
    uint32_t x = (uint32_t)a, y = (uint32_t)b, bits = 0;
    switch (kind) {
        case JARBOX_LEAF_ABS: bits = a < 0 ? 0u - x : x; break;
        case JARBOX_LEAF_IDENTITY: bits = x; break;
        case JARBOX_LEAF_NEGATE: bits = 0u - x; break;
        case JARBOX_LEAF_ADD: bits = x + y; break;
        case JARBOX_LEAF_SUB: bits = x - y; break;
        case JARBOX_LEAF_MUL: bits = x * y; break;
        case JARBOX_LEAF_AND: bits = x & y; break;
        case JARBOX_LEAF_OR: bits = x | y; break;
        case JARBOX_LEAF_XOR: bits = x ^ y; break;
        default: return (int32_t)kind - JARBOX_LEAF_CONST_M1 - 1;
    }
    int32_t result;
    memcpy(&result, &bits, sizeof(result));
    return result;
}
#endif
