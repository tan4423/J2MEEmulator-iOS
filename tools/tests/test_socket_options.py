"""Compile real miniJVM socket option functions and check OS-level effects.

Host TCP loopback test only; no remote NSO endpoint, no full JVM or iOS build.
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
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <arpa/inet.h>
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
#define SOCK_OP_TYPE_NODELAY 7
static int mbedtls_net_set_nonblock(NetCtx *ctx) {int f = fcntl(ctx->fd, F_GETFL); return f < 0 ? -1 : fcntl(ctx->fd, F_SETFL, f | O_NONBLOCK);}
static int mbedtls_net_set_block(NetCtx *ctx) {int f = fcntl(ctx->fd, F_GETFL); return f < 0 ? -1 : fcntl(ctx->fd, F_SETFL, f & ~O_NONBLOCK);}
"""
TEST = r"""
int main(void) {
    // SO_KEEPALIVE is a TCP option. AF_UNIX socketpair does not promise to
    // store/report this option consistently (macOS returned 0 after set).
    // Exercise the real TCP implementation using loopback + an ephemeral port:
    // no outside network connection, DNS, or external service involved.
    int listener = socket(AF_INET, SOCK_STREAM, 0);
    if (listener < 0) return 1;
    struct sockaddr_in addr = {0};
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    addr.sin_port = htons(0);
    if (bind(listener, (const struct sockaddr *)&addr, sizeof(addr)) != 0)
        return 14;
    if (listen(listener, 1) != 0) return 15;
    socklen_t addr_len = sizeof(addr);
    if (getsockname(listener, (struct sockaddr *)&addr, &addr_len) != 0)
        return 16;
    int client = socket(AF_INET, SOCK_STREAM, 0);
    if (client < 0) return 17;
    if (connect(client, (const struct sockaddr *)&addr, sizeof(addr)) != 0)
        return 18;
    int accepted = accept(listener, NULL, NULL);
    if (accepted < 0) return 19;
    VmSock s = {0};
    s.contex.fd = client;
    if (sock_option(&s, SOCK_OP_TYPE_TIMEOUT, 750, 0)) return 2;
    int baseline = sock_get_option(&s, SOCK_OP_TYPE_TIMEOUT);
    if (baseline < 700 || baseline > 900) return 3;

    if (sock_option(&s, SOCK_OP_TYPE_KEEPALIVE, 1, 0)) return 4;
    int keepalive = sock_get_option(&s, SOCK_OP_TYPE_KEEPALIVE);
    int raw_keepalive = 0;
    socklen_t keepalive_len = sizeof(raw_keepalive);
    if (getsockopt(client, SOL_SOCKET, SO_KEEPALIVE,
                   &raw_keepalive, &keepalive_len) != 0 ||
        raw_keepalive == 0 || keepalive != 1) {
        fprintf(stderr, "SO_KEEPALIVE normalized=%d raw=%d\\n",
                keepalive, raw_keepalive);
        return 5;
    }
    if (sock_get_option(&s, SOCK_OP_TYPE_TIMEOUT) != baseline) return 6;

    if (sock_option(&s, SOCK_OP_TYPE_LINGER, 1, 4)) return 7;
    // Darwin SO_LINGER may use ticks; Linux reports seconds. Test the
    // enabled state without assuming a cross-platform interval encoding.
    int linger = sock_get_option(&s, SOCK_OP_TYPE_LINGER);
    struct linger raw_linger = {0};
    socklen_t linger_len = sizeof(raw_linger);
    if (getsockopt(client, SOL_SOCKET, SO_LINGER,
                   &raw_linger, &linger_len) != 0 ||
        raw_linger.l_onoff == 0 || linger <= 0) return 8;
    if (sock_get_option(&s, SOCK_OP_TYPE_TIMEOUT) != baseline) return 9;

    if (sock_option(&s, SOCK_OP_TYPE_KEEPALIVE, 0, 0)) return 10;
    raw_keepalive = -1;
    keepalive_len = sizeof(raw_keepalive);
    if (sock_get_option(&s, SOCK_OP_TYPE_KEEPALIVE) != 0 ||
        getsockopt(client, SOL_SOCKET, SO_KEEPALIVE,
                   &raw_keepalive, &keepalive_len) != 0 ||
        raw_keepalive != 0) return 11;
    if (sock_option(&s, SOCK_OP_TYPE_LINGER, 0, 0)) return 12;
    if (sock_get_option(&s, SOCK_OP_TYPE_LINGER) != -1) return 13;
    if (sock_option(&s, SOCK_OP_TYPE_NON_BLOCK, 1, 0) || !s.non_block ||
        !(fcntl(client, F_GETFL) & O_NONBLOCK)) return 20;
    if (sock_option(&s, SOCK_OP_TYPE_NON_BLOCK, 0, 0) || s.non_block ||
        (fcntl(client, F_GETFL) & O_NONBLOCK)) return 21;
    if (sock_option(&s, SOCK_OP_TYPE_TIMEOUT, -1, 0) == 0 ||
        s.rcv_time_out != 750) return 22;
    if (sock_option(&s, SOCK_OP_TYPE_NODELAY, 1, 0) ||
        sock_get_option(&s, SOCK_OP_TYPE_NODELAY) != 1) return 25;
    if (sock_option(&s, SOCK_OP_TYPE_NODELAY, 0, 0) ||
        sock_get_option(&s, SOCK_OP_TYPE_NODELAY) != 0) return 26;
    close(client);
    s.contex.fd = -1;
    if (sock_option(&s, SOCK_OP_TYPE_NON_BLOCK, 1, 0) == 0 || s.non_block)
        return 23;
    if (sock_option(&s, SOCK_OP_TYPE_TIMEOUT, 100, 0) == 0 ||
        s.rcv_time_out != 750) return 24;
    close(accepted); close(listener); return 0;
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
        self.assertIn("socket(AF_INET, SOCK_STREAM, 0)", TEST)
        self.assertNotIn("socketpair(AF_UNIX", TEST)
        self.assertIn("SO_LINGER", funcs)
        self.assertIn("SO_KEEPALIVE", funcs)
        self.assertIn("ret = ret != 0 ? 1 : 0;", funcs)
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
