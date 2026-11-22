"""Compile real socket availability helper and test OS queued TCP-like bytes.

This is a POSIX socketpair test, not an NSO connection or on-device proof.
It neither contacts a remote server nor fabricates game server responses.
"""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
NATIVE = ROOT / "J2MEEmulator/minijvm/jvm"
SOURCE = NATIVE / "jni_io.c"

PROGRAM = r"""
#include <sys/types.h>
#include <sys/socket.h>
#include <unistd.h>
#include <string.h>
#include "socket_compat.h"
int main(void) {
    int a[2], b[2];
    if (socketpair(AF_UNIX, SOCK_STREAM, 0, a) != 0) return 1;
    if (socketpair(AF_UNIX, SOCK_STREAM, 0, b) != 0) return 2;
    if (jarbox_socket_bytes_available(a[0]) != 0) return 3;
    if (jarbox_socket_bytes_available(b[0]) != 0) return 4;
    const char msg[] = "abcd";
    if (send(a[1], msg, 4, 0) != 4) return 5;
    if (jarbox_socket_bytes_available(a[0]) != 4) return 6;
    if (jarbox_socket_bytes_available(b[0]) != 0) return 7;
    char buf[8];
    if (recv(a[0], buf, 1, 0) != 1) return 8;
    if (jarbox_socket_bytes_available(a[0]) != 3) return 9;
    if (send(b[1], msg, 2, 0) != 2) return 10;
    if (jarbox_socket_bytes_available(b[0]) != 2) return 11;
    if (jarbox_socket_bytes_available(a[0]) != 3) return 12;
    close(a[0]); close(a[1]); close(b[0]); close(b[1]);
    if (jarbox_socket_bytes_available(-1) != 0) return 13;
    return 0;
}
"""

class SocketAvailabilityTest(unittest.TestCase):
    def test_source_calls_real_helper_and_has_no_polling(self):
        source = SOURCE.read_text(encoding="utf-8")
        body = source[source.index("s32 org_mini_net_SocketNative_available0("):
                      source.index("s32 org_mini_net_SocketNative_close0(", source.index("s32 org_mini_net_SocketNative_available0("))]
        self.assertIn("jarbox_socket_bytes_available(sock->contex.fd)", body)
        self.assertIn("tcp_first_available:has_pending_bytes", body)
        self.assertNotIn("push_int(runtime->stack, 0)", body)

    def test_socketpair_pending_bytes_per_handle(self):
        if shutil.which("cc") is None:
            self.skipTest("C compiler unavailable")
        with tempfile.TemporaryDirectory(prefix="jarbox-socket-available-") as temp:
            path = Path(temp)
            src = path / "test.c"
            exe = path / "test"
            src.write_text(PROGRAM, encoding="utf-8")
            build = subprocess.run(
                ["cc", "-std=c11", "-O2", "-Wall", "-Wextra", "-I", str(NATIVE),
                 str(src), "-o", str(exe)],
                capture_output=True, text=True, timeout=40)
            self.assertEqual(build.returncode, 0, build.stdout + build.stderr)
            run = subprocess.run([str(exe)], capture_output=True, text=True, timeout=10)
            self.assertEqual(run.returncode, 0, run.stdout + run.stderr)

if __name__ == "__main__":
    unittest.main()
