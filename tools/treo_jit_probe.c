// Opt-in allocator and code execution probe. Does not enable the VM JIT.
#include <stdint.h>
#include "sljitLir.h"

int32_t treo_jit_probe(void) {
    struct sljit_compiler *compiler = sljit_create_compiler(NULL);
    if (!compiler) return -1;
    sljit_s32 err = sljit_emit_enter(compiler, 0, SLJIT_ARGS0(W), 1, 0, 0);
    if (!err) err = sljit_emit_return(compiler, SLJIT_MOV, SLJIT_IMM, 42);
    if (err) {
        sljit_free_compiler(compiler);
        return -100 - err;
    }
    void *entry = sljit_generate_code(compiler, 0, NULL);
    err = sljit_get_compiler_error(compiler);
    sljit_free_compiler(compiler);
    if (!entry) return -200 - err;
    sljit_sw result = ((sljit_sw (*)(void))entry)();
    sljit_free_code(entry, NULL);
    sljit_free_unused_memory_exec();
    return result == 42 ? 42 : -300;
}
