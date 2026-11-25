"""Compile exact production transport helpers against scripted I/O and OS poll.

No external connections, MIDlet execution, or fabricated game responses.
"""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
IO = ROOT / "J2MEEmulator/minijvm/jvm/jni_io.c"
NET = ROOT / "J2MEEmulator/minijvm/utils/https/mbedtls/library/net_sockets.c"
VM = ROOT / "J2MEEmulator/minijvm/jvm/interpreter.c"
STUB = r"""
#include <stdint.h>
#include <stdio.h>
#include <limits.h>
typedef int32_t s32;
typedef int64_t s64;
typedef uint8_t u8;
typedef struct { int fd; } NetCtx;
typedef struct { NetCtx contex; s32 rcv_time_out; int non_block; } VmSock;
typedef struct { int is_interrupt; } Thread;
typedef struct { Thread *thrd_info; } Runtime;
#define MBEDTLS_ERR_SSL_TIMEOUT -10
#define MBEDTLS_ERR_SSL_WANT_READ -11
#define MBEDTLS_ERR_SSL_WANT_WRITE -12
static int steps[16], n, pos, maxwait, now, interrupt_after;
static Thread th;
static s64 nanoTime(void) { return (s64)now * 1000000; }
static void thrd_yield(void) { now++; }
static int next(u8 *p, int wait) {
    if (wait > maxwait) maxwait = wait;
    if (pos >= n) return 0;
    int r = steps[pos++];
    if (r == MBEDTLS_ERR_SSL_TIMEOUT) now += wait;
    if (r > 0 && p) *p = 0; // valid received NUL
    if (interrupt_after && pos >= interrupt_after) th.is_interrupt = 1;
    return r;
}
static int mbedtls_net_recv(NetCtx *ctx, u8 *p, int nbytes) {(void)ctx;(void)nbytes;return next(p,0);}
static int mbedtls_net_recv_timeout(NetCtx *ctx, u8 *p, int nbytes, int wait) {(void)ctx;(void)nbytes;return next(p,wait);}
static int mbedtls_net_send(NetCtx *ctx, const u8 *p, int nbytes) {(void)ctx;(void)p;(void)nbytes;return next(0,0);}
static void reset(int a,int b,int c,int d,int size) {
    steps[0]=a;steps[1]=b;steps[2]=c;steps[3]=d;
    n=size;pos=now=maxwait=interrupt_after=th.is_interrupt=0;
}
"""
MAIN = r"""
#define CHECK(x) do { if (!(x)) { fprintf(stderr,"failure line %d\n",__LINE__); return 1; } } while(0)
int main(void) {
    VmSock s = {0}; Runtime rt = {&th}; u8 b[8] = {42};
    reset(MBEDTLS_ERR_SSL_WANT_READ,1,0,0,2);
    CHECK(sock_recv(&s,b,1,&rt)==1 && pos==2 && b[0]==0);
    CHECK(jarbox_socket_byte_result(1,b[0])==0);
    reset(MBEDTLS_ERR_SSL_WANT_READ,1,0,0,2);
    s.non_block=1;
    CHECK(sock_recv(&s,b,1,&rt)==0 && pos==1);
    CHECK(jarbox_socket_byte_result(0,0)==-2);
    s.non_block=0;s.rcv_time_out=250;
    reset(MBEDTLS_ERR_SSL_TIMEOUT,MBEDTLS_ERR_SSL_TIMEOUT,MBEDTLS_ERR_SSL_TIMEOUT,0,3);
    CHECK(sock_recv(&s,b,1,&rt)==-2 && now==250 && maxwait==100);
    reset(MBEDTLS_ERR_SSL_TIMEOUT,1,0,0,2);interrupt_after=1;
    CHECK(sock_recv(&s,b,1,&rt)==-1 && pos==1);
    reset(0,0,0,0,1);
    CHECK(sock_recv(&s,b,1,&rt)==-1 && jarbox_socket_byte_result(-1,0)==-1);
    reset(1,0,0,0,1);
    CHECK(sock_recv(&s,b,0,&rt)==0 && pos==0);
    CHECK(sock_send(&s,b,0,&rt)==0 && pos==0);
    reset(MBEDTLS_ERR_SSL_WANT_WRITE,1,0,0,2);
    CHECK(sock_send(&s,b,1,&rt)==1 && pos==2);
    s.non_block=1;reset(MBEDTLS_ERR_SSL_WANT_WRITE,1,0,0,2);
    CHECK(sock_send(&s,b,1,&rt)==0 && pos==1);
    s.non_block=0;reset(2,0,0,0,1);
    CHECK(sock_send(&s,b,8,&rt)==2 && pos==1);
    CHECK(jarbox_socket_range_valid(8,8,0));
    CHECK(jarbox_socket_range_valid(8,3,5));
    CHECK(!jarbox_socket_range_valid(8,3,6));
    CHECK(!jarbox_socket_range_valid(8,-1,1));
    CHECK(!jarbox_socket_range_valid(8,1,INT_MAX));
    CHECK(!jarbox_socket_range_valid(8,INT_MAX,1));
    return 0;
}
"""
POLL_STUB = r"""
#include <stdint.h>
#include <limits.h>
#include <stddef.h>
#include <errno.h>
#include <poll.h>
#include <sys/types.h>
#include <sys/socket.h>
#include <sys/select.h>
#include <fcntl.h>
#include <unistd.h>
typedef struct { int fd; } mbedtls_net_context;
#define MBEDTLS_ERR_NET_INVALID_CONTEXT -1
#define MBEDTLS_ERR_SSL_TIMEOUT -2
#define MBEDTLS_ERR_SSL_WANT_READ -3
#define MBEDTLS_ERR_NET_RECV_FAILED -4
static int mbedtls_net_recv(void *ctx, unsigned char *b, size_t n) {
    return (int)read(((mbedtls_net_context *)ctx)->fd,b,n);
}
"""
POLL_MAIN = r"""
int main(void) {
    int pair[2]; unsigned char b=0;
    if(socketpair(AF_UNIX,SOCK_STREAM,0,pair))return 1;
    int high=fcntl(pair[0],F_DUPFD,FD_SETSIZE+16);
    mbedtls_net_context ctx={high>=0?high:pair[0]};
    if(mbedtls_net_recv_timeout(&ctx,&b,1,2)!=MBEDTLS_ERR_SSL_TIMEOUT)return 2;
    if(write(pair[1],"x",1)!=1 || mbedtls_net_recv_timeout(&ctx,&b,1,20)!=1 || b!='x')return 3;
    close(pair[1]);
    if(mbedtls_net_recv_timeout(&ctx,&b,1,20)!=0)return 4;
    if(high>=0)close(high);
    close(pair[0]);
    if(mbedtls_net_recv_timeout(&ctx,&b,1,20)!=MBEDTLS_ERR_NET_INVALID_CONTEXT)return 5;
    return 0;
}
"""

class SocketTransportContractTest(unittest.TestCase):
    def compile_run(self, program):
        cc = shutil.which("cc")
        if not cc:
            self.skipTest("host C compiler unavailable")
        with tempfile.TemporaryDirectory() as td:
            src, exe = Path(td)/"transport.c", Path(td)/"transport"
            src.write_text(program)
            subprocess.run([cc,"-std=c11","-O1","-Wall","-Wextra",str(src),"-o",str(exe)],check=True,timeout=30)
            subprocess.run([str(exe)],check=True,timeout=10)

    def test_retry_timeout_cancel_and_byte_semantics(self):
        source = IO.read_text()
        a = source.index("static s32 sock_recv(")
        b = source.index("\ns32 org_mini_net_SocketNative_readBuf(",a)
        self.compile_run(STUB+source[a:b]+MAIN)
        self.assertIn("push_int(runtime->stack, jarbox_socket_byte_result(ret, b));",source)
        self.assertEqual(source.count("jarbox_socket_range_valid(jbyte_arr->arr_length, offset, count)"),2)

    def test_poll_timeout_eof_and_high_descriptor_when_available(self):
        source = NET.read_text()
        a = source.index("int mbedtls_net_recv_timeout(")
        b = source.index("\n/*",a)
        self.compile_run(POLL_STUB+source[a:b]+POLL_MAIN)

    def test_missing_symbols_and_popup_trace_are_not_four_pc_only(self):
        source = VM.read_text()
        self.assertIn("treo_diag_version_gate(runtime, ca)",source)
        self.assertIn("treo_diag_popup_origin(pruntime, method)",source)
        self.assertIn("reject[0] == op_aconst_null",source)
        self.assertIn("reject[1] == op_putstatic_ref",source)
        self.assertIn("target += 4;",source)
        self.assertIn("index >= clazz->constant_item_count",source)
        self.assertIn("item->tag != CONSTANT_METHOD_REF",source)
        self.assertIn('"vm_missing_method"',source)
        self.assertIn('"vm_missing_field:',source)
        self.assertIn("cmr = NULL; // invokedynamic",source)

if __name__ == "__main__":
    unittest.main()
