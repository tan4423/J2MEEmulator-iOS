#undef signal
/* Host-only stubs: the smoke test does not exercise the sljit JIT or TLS. */
#include "jvm.h"
#include "jit.h"
#include "ssl_client.h"
void jit_init(CodeAttribute *ca) { (void)ca; }
void jit_destroy(Jit *jit) { (void)jit; }
void construct_jit(MethodInfo *m, Runtime *r) {
    (void)r; if (m && m->converted_code) m->converted_code->jit.state = JIT_GEN_ERROR;
}
void jit_set_exception_jump_addr(Runtime *r, CodeAttribute *ca, s32 i) { (void)r;(void)ca;(void)i; }
int sslc_init(SSLC_Entry *e){(void)e;return -1;}
int sslc_wrap(SSLC_Entry *e,int fd,char *h){(void)e;(void)fd;(void)h;return -1;}
int sslc_connect(SSLC_Entry *e,char *h,char *p){(void)e;(void)h;(void)p;return -1;}
int sslc_write(SSLC_Entry *e,char *b,int n){(void)e;(void)b;(void)n;return -1;}
int sslc_read(SSLC_Entry *e,char *b,int n){(void)e;(void)b;(void)n;return -1;}
int sslc_close(SSLC_Entry *e){(void)e;return -1;}

/* Harness-only: keep the host's crash backtrace handler; miniJVM's jvm_init()
 * installs process-wide SIGABRT/SIGSEGV handlers that would hide it. */
#include <signal.h>
#include <execinfo.h>
#include <unistd.h>
static void smoke_bt(int sig) {
    void *bt[40]; int n = backtrace(bt, 40);
    dprintf(2, "SMOKE-CRASH signal %d\n", sig); backtrace_symbols_fd(bt, n, 2); _exit(128 + sig);
}
void smoke_install_crash_handler(void) {
    struct sigaction sa = {0}; sa.sa_handler = smoke_bt; sigaction(SIGABRT, &sa, 0); sigaction(SIGSEGV, &sa, 0);
}
void (*smoke_signal(int sig, void (*h)(int)))(int) {
    if (sig == SIGABRT || sig == SIGSEGV) return SIG_DFL;
    struct sigaction sa = {0}, old = {0}; sa.sa_handler = h; sigaction(sig, &sa, &old); return old.sa_handler;
}
