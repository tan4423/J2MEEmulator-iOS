// Opt-in allocator and code execution probe. Does not enable the VM JIT.
#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <sys/mman.h>
#include <unistd.h>
#include "sljitLir.h"

// Independent diagnostics after SLJIT reports an executable allocation
// failure. No bytes from these mappings are executed.
static int32_t treo_jit_mapping_diagnostics(void) {
    const size_t size = (size_t)getpagesize();
    const int base_flags = MAP_PRIVATE | MAP_ANON;
    int allocator_flags = base_flags;
#ifdef MAP_JIT
    allocator_flags |= MAP_JIT;
#endif
    void *page = mmap(NULL, size, PROT_READ | PROT_WRITE | PROT_EXEC,
                      allocator_flags, -1, 0);
    int map_error = 0;
    if (page == MAP_FAILED) {
        map_error = errno;
    } else {
        munmap(page, size);
    }

    int transition_code = 0;
    page = mmap(NULL, size, PROT_READ | PROT_WRITE, base_flags, -1, 0);
    if (page == MAP_FAILED) {
        transition_code = 500 + errno;
    } else {
        // Mark the page dirty to exercise a write-to-execute transition.
        *(volatile unsigned char *)page = 0;
        if (mprotect(page, size, PROT_READ | PROT_EXEC) != 0)
            transition_code = errno;
        munmap(page, size);
    }

    fprintf(stderr, "[TREO-JIT] allocator-style mmap errno=%d; RW-to-RX diagnostic=%d\n",
            map_error, transition_code);
    // Preserve both outcomes in the existing on-screen integer report.
    return -(1000000 + 1000 * map_error + transition_code);
}

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
    if (!entry) {
        if (err == SLJIT_ERR_EX_ALLOC_FAILED)
            return treo_jit_mapping_diagnostics();
        return -200 - err;
    }
    sljit_sw result = ((sljit_sw (*)(void))entry)();
    sljit_free_code(entry, NULL);
    sljit_free_unused_memory_exec();
    return result == 42 ? 42 : -300;
}
