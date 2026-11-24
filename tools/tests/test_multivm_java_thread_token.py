"""Production C thread-token implementation: two concurrent Java worker owners.

This compiles the exact self-contained TLS block from jvm_bridge.c rather than
a reimplementation. It proves pthread token isolation, not two miniJVM heaps.
"""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / "J2MEEmulator/NativeBridge/jvm_bridge.c"

HARNESS = r"""
#include <stdint.h>
#include <pthread.h>
#include <stdio.h>
#include <stdatomic.h>
#include <sched.h>
typedef struct {
    uint64_t token;
    atomic_int *failure;
} Worker;
static void *work(void *raw) {
    Worker *w = (Worker *)raw;
    if (jvm_bridge_thread_token() != 0) atomic_store(w->failure, 1);
    for (int i = 0; i < 10000; ++i) {
        const uint64_t previous = jvm_bridge_push_java_thread_token(w->token);
        if (previous != 0 || jvm_bridge_thread_token() != w->token)
            atomic_store(w->failure, 2);
        const uint64_t nested = jvm_bridge_push_java_thread_token(w->token + 1000);
        if (nested != w->token || jvm_bridge_thread_token() != w->token + 1000)
            atomic_store(w->failure, 3);
        jvm_bridge_pop_java_thread_token(nested);
        if (jvm_bridge_thread_token() != w->token)
            atomic_store(w->failure, 4);
        jvm_bridge_pop_java_thread_token(previous);
        if (jvm_bridge_thread_token() != 0) atomic_store(w->failure, 5);
        if (!(i % 137)) sched_yield();
    }
    return NULL;
}
int main(void) {
    atomic_int failure = 0;
    Worker a = {101, &failure}, b = {202, &failure};
    pthread_t ta, tb;
    if (pthread_create(&ta, NULL, work, &a) ||
        pthread_create(&tb, NULL, work, &b)) return 6;
    pthread_join(ta, NULL);
    pthread_join(tb, NULL);
    if (atomic_load(&failure) || jvm_bridge_thread_token()) return 7;
    puts("per-Java-pthread owner token: PASS");
    return 0;
}
"""

class MultiVMJavaThreadTokenTest(unittest.TestCase):
    def test_real_pthread_token_binding_and_restoration(self):
        cc = shutil.which("cc") or shutil.which("clang")
        if not cc: self.skipTest("Host compiler not found")
        text = SOURCE.read_text(encoding="utf-8")
        start = text.index("static _Thread_local uint64_t g_bridge_java_thread_token;")
        end = text.index("// One visible window", start)
        block = text[start:end]
        self.assertIn("jvm_bridge_pop_java_thread_token", block)
        with tempfile.TemporaryDirectory(prefix="jarbox-token-threads-") as td:
            src, exe = Path(td) / "tokens.c", Path(td) / "tokens"
            src.write_text("#include <stdint.h>\n" + block + HARNESS, encoding="utf-8")
            build = subprocess.run(
                [cc, "-std=c11", "-O2", "-Wall", "-Wextra", "-Werror",
                 "-pthread", str(src), "-o", str(exe)],
                capture_output=True, text=True, timeout=45)
            self.assertEqual(build.returncode, 0, build.stdout + build.stderr)
            run = subprocess.run([str(exe)], capture_output=True, text=True, timeout=30)
            self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
            self.assertIn("per-Java-pthread owner token: PASS", run.stdout)

    def test_workers_keep_session_identity_after_focus_switch(self):
        bridge = SOURCE.read_text(encoding="utf-8")
        runtime = (ROOT / "J2MEEmulator/minijvm/jvm/jvm_util.c").read_text(encoding="utf-8")
        self.assertIn("jvm_bridge_push_java_thread_token(held_session->token)", runtime)
        self.assertEqual(runtime.count("jvm_bridge_pop_java_thread_token(previous_token);"), 2)
        self.assertIn("const uint64_t bound = jvm_bridge_thread_token();", bridge)
        self.assertIn("jvm_bridge_push_java_thread_token(token);", bridge)
        self.assertIn("jvm_bridge_pop_java_thread_token(previous);", bridge)
        self.assertIn("int jvm_bridge_supported_concurrent_sessions(void) {\n    return JARBOX_REGISTRY_MAX_SLOTS;", bridge)

if __name__ == "__main__":
    unittest.main()
