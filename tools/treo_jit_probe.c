// Opt-in allocator and code execution probe. Does not enable the VM JIT.
#include <errno.h>
#include <libkern/OSCacheControl.h>
#include <string.h>
#include <stdint.h>
#include <stdio.h>
#include <sys/mman.h>
#include <unistd.h>
#include "sljitLir.h"

// Independent opt-in execution test after SLJIT's allocator fails.
// Write a single fixed function on an RW page, then switch it to RX.
static int32_t treo_jit_mapping_diagnostics(void) {
    // ARM64 little endian: mov w0, #42; ret.
    static const uint32_t code[] = { 0x52800540u, 0xd65f03c0u };
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
        memcpy(page, code, sizeof(code));
        if (mprotect(page, size, PROT_READ | PROT_EXEC) != 0) {
            transition_code = errno;
        } else {
            fprintf(stderr, "[TREO-JIT] allocator-style mmap errno=%d; executing RW-to-RX probe\n",
                    map_error);
            sys_icache_invalidate(page, sizeof(code));
            int32_t value = ((int32_t (*)(void))page)();
            munmap(page, size);
            fprintf(stderr, "[TREO-JIT] RW-to-RX probe returned %d\n", value);
            return value == 42 ? 42 : -301;
        }
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
