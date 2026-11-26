#ifndef JARBOX_CONST_FUSION_H
#define JARBOX_CONST_FUSION_H
#include <stddef.h>

/* Independent, opt-in handler chaining. No new opcode, prepared-code layout,
 * mutable shared state or skipped Java operation. Included after JVM opcodes. */
#ifndef TREO_VM_CONST_ARITH_FUSION_EXPERIMENT
#define TREO_VM_CONST_ARITH_FUSION_EXPERIMENT 0
#endif
#ifndef TREO_VM_CONST_BRANCH_FUSION_EXPERIMENT
#define TREO_VM_CONST_BRANCH_FUSION_EXPERIMENT 0
#endif

#if TREO_VM_DIRECT_DISPATCH && !_JVM_DEBUG_PROFILE && _JVM_DEBUG_LOG_LEVEL == 0 && !defined(__JVM_DEBUG__) && (TREO_VM_CONST_ARITH_FUSION_EXPERIMENT || TREO_VM_CONST_BRANCH_FUSION_EXPERIMENT)
#define TREO_VM_CONST_FUSION 1
static inline int jarbox_const_fusion_target(unsigned op, size_t remaining) {
    if (!remaining) return 0;
#if TREO_VM_CONST_ARITH_FUSION_EXPERIMENT
    switch (op) {
        case op_iadd: case op_isub: case op_imul:
        case op_ishl: case op_ishr: case op_iushr:
        case op_iand: case op_ior: case op_ixor:
            return 1;
        default: break;
    }
#endif
#if TREO_VM_CONST_BRANCH_FUSION_EXPERIMENT
    // The original comparison handler reads a two-byte branch displacement
    // and performs check_gc_pause on taken branches, including backedges.
    if (remaining >= 3 && op >= op_if_icmpeq && op <= op_if_icmple) return 1;
#endif
    return 0;
}
// Called only after the original integer constant handler has pushed its
// value and advanced PC. The target cannot chain again; normal dispatch
// resumes after one additional original opcode. Never bypass JDWP.
#ifndef JARBOX_CONST_FUSION_NOTE
#define JARBOX_CONST_FUSION_NOTE(op) ((void)(op))
#endif
#define TREO_VM_FUSE_INT_CONSTANT() do { \
    if (treo_vm_use_direct && runtime->pc < treo_vm_code_end) { \
        const unsigned next = *runtime->pc; \
        if (jarbox_const_fusion_target(next, (size_t)(treo_vm_code_end - runtime->pc))) { \
            JARBOX_CONST_FUSION_NOTE(next); \
            goto *treo_vm_targets[next]; \
        } \
    } \
} while (0)
#else
#define TREO_VM_CONST_FUSION 0
#define TREO_VM_FUSE_INT_CONSTANT() ((void)0)
#endif
#endif
