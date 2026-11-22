"""Compile real miniJVM socket option functions and check OS-level effects.

Host socketpair test only; no remote NSO endpoint, no full JVM or iOS build.
"""
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
NATIVE = ROOT / "J2MEEmulator/minijvm/jvm/jni_io.c"

PREAMBLE = r"""
#include <stdint.h>
#include <sys/types.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <unistd.h>
#include <fcntl.h>
#include <stdio.h>
typedef int s32;
typedef char c8;
typedef struct { int fd; } NetCtx;
typedef struct {
    NetCtx contex;
    int rcv_time_out;
    int non_block;
    int reuseaddr;
} VmSock;
#define SOCK_OP_TYPE_NON_BLOCK 0
#define SOCK_OP_TYPE_REUSEADDR 1
#define SOCK_OP_TYPE_RCVBUF 2
#define SOCK_OP_TYPE_SNDBUF 3
#define SOCK_OP_TYPE_KEEPALIVE 4
#define SOCK_OP_TYPE_LINGER 5
#define SOCK_OP_TYPE_TIMEOUT 6
static int mbedtls_net_set_nonblock(NetCtx *ctx) {(void)ctx; return 0;}
static int mbedtls_net_set_block(NetCtx *ctx) {(void)ctx; return 0;}
"""
TEST = r"""
int main(void) {
    int sv[2];
    if (socketpair(AF_UNIX, SOCK_STREAM, 0, sv) != 0) return 1;
    VmSock s = {0};
    s.contex.fd = sv[0];
    if (sock_option(&s, SOCK_OP_TYPE_TIMEOUT, 750, 0)) return 2;
    int baseline = sock_get_option(&s, SOCK_OP_TYPE_TIMEOUT);
    if (baseline < 700 || baseline > 900) return 3;

    if (sock_option(&s, SOCK_OP_TYPE_KEEPALIVE, 1, 0)) return 4;
    if (sock_get_option(&s, SOCK_OP_TYPE_KEEPALIVE) != 1) return 5;
    if (sock_get_option(&s, SOCK_OP_TYPE_TIMEOUT) != baseline) return 6;

    if (sock_option(&s, SOCK_OP_TYPE_LINGER, 1, 4)) return 7;
    if (sock_get_option(&s, SOCK_OP_TYPE_LINGER) != 4) return 8;
    if (sock_get_option(&s, SOCK_OP_TYPE_TIMEOUT) != baseline) return 9;

    if (sock_option(&s, SOCK_OP_TYPE_KEEPALIVE, 0, 0)) return 10;
    if (sock_get_option(&s, SOCK_OP_TYPE_KEEPALIVE) != 0) return 11;
    if (sock_option(&s, SOCK_OP_TYPE_LINGER, 0, 0)) return 12;
    if (sock_get_option(&s, SOCK_OP_TYPE_LINGER) != -1) return 13;
    close(sv[0]); close(sv[1]); return 0;
}
"""

class SocketOptionsTest(unittest.TestCase):
    def test_real_c_socket_options_no_longer_rewrite_receive_timeout(self):
        cc = shutil.which("cc")
        if not cc:
            self.skipTest("C compiler unavailable")
        code = NATIVE.read_text(encoding="utf-8")
        start = code.index("s32 sock_option(VmSock *vmsock")
        end = code.index("\ns32 host_2_ip(", start)
        funcs = code[start:end]
        self.assertIn("SO_LINGER", funcs)
        self.assertIn("SO_KEEPALIVE", funcs)
        with tempfile.TemporaryDirectory(prefix="jarbox-socket-options-") as t:
            src = Path(t) / "options.c"
            exe = Path(t) / "options"
            src.write_text(PREAMBLE + funcs + "\n" + TEST)
            compile_result = subprocess.run(
                [cc, "-std=c11", "-O1", "-Wall", "-Wextra",
                 str(src), "-o", str(exe)], capture_output=True,
                text=True, timeout=45)
            self.assertEqual(compile_result.returncode, 0,
                             compile_result.stdout + compile_result.stderr)
            run = subprocess.run([str(exe)], capture_output=True, text=True, timeout=15)
            self.assertEqual(run.returncode, 0, run.stdout + run.stderr)

if __name__ == "__main__":
    unittest.main()
