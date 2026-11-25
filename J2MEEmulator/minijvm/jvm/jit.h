//
// Created by root on 10/30/19.
//

#ifndef MINI_JVM_JIT_H
#define MINI_JVM_JIT_H
#ifdef __cplusplus
extern "C" {
#endif

#include "jvm.h"
#include "jvm_util.h"

#if defined(TREO_IOS_GAME_JIT) && __JVM_OS_IOS__ && !__JVM_ARCH_32__
    #define JIT_ENABLE 1
#elif __JVM_OS_IOS__ || __JVM_OS_CYGWIN__ || __JVM_ARCH_32__
    #define JIT_ENABLE 0
#else
    #define JIT_ENABLE 01
#endif

#define JIT_COMPILE_EXEC_COUNT 5000
#define JIT_DEBUG 0

#define SLJIT_CONFIG_AUTO 1
#define JIT_CODE_DUMP 0

enum {
    LOCAL_METHOD = 0,
    LOCAL_RUNTIME,
    LOCAL_STACK_SP,
    LOCAL_RUNTIME_PC,
    LOCAL_STACK,
    LOCAL_THREADINFO,
    LOCAL_R0,//for save_ip_sp
    LOCAL_R2,//for check_suspend
    LOCAL_COUNT,
};

enum {
    JIT_GEN_UNKNOW = 0,
    JIT_GEN_COMPILING,
    JIT_GEN_ERROR,
    JIT_GEN_SUCCESS,
};


typedef void (*thread_suspend_check_func)();

struct _SwitchTable {
    struct _SwitchTable  *next;
    s32 size;//table length
    struct V2PTable {
        s32 value; //for value
        s32 bc_pos;//for get label addr
        __refer jump_ptr;
    } *table;
};

void jit_init(CodeAttribute *ca) ;

void jit_destroy(Jit *jit);

void construct_jit(MethodInfo *method, Runtime *runtime);
#ifdef TREO_IOS_GAME_JIT
int treo_game_jit_is_enabled(void);
// Interpreter calls this on the hot path; retain the external ABI above
// for Swift/bridge callers. Same relaxed atomic state, no cached decision.
#if JIT_ENABLE
extern int treo_jit_enabled_state;
static inline int treo_game_jit_enabled_fast(void) {
    return __atomic_load_n(&treo_jit_enabled_state, __ATOMIC_RELAXED);
}
#else
static inline int treo_game_jit_enabled_fast(void) { return 0; }
#endif
void treo_game_jit_set_enabled(int enabled);
int treo_game_jit_compiled_count(void);
int treo_game_jit_call_count(void);
int treo_game_jit_backend_probe(void);
int treo_game_jit_fallback_count(void);
int treo_game_jit_code_kib(void);
void treo_game_jit_record_call(void);
int treo_game_jit_can_compile(MethodInfo *method);
#endif

void jit_set_exception_jump_addr(Runtime* runtime, CodeAttribute *ca, s32 index);

#ifdef __cplusplus
}
#endif
#endif //MINI_JVM_JIT_H
