"""Build the production session header and race native callbacks vs STOPPING.

Host C11/pthreads only: neither iOS background execution nor UIKit is tested.
"""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
HEADER = ROOT / "J2MEEmulator/minijvm/jvm/jarbox_session.h"
C = r"""
#include <stdint.h>
#include <pthread.h>
#include <stdatomic.h>
#include <sched.h>
#include <stdio.h>
#include "jarbox_session.h"
typedef struct { JarBoxSession *session; atomic_int started, done; } Task;
static void *callback(void *ctx) {
    Task *t = ctx;
    if (!jarbox_session_reserve_callback(t->session)) return NULL;
    atomic_store(&t->started, 1);
    while (!atomic_load(&t->done)) sched_yield();
    jarbox_session_callback_done(t->session);
    return NULL;
}
static void *race(void *ctx) {
    Task *t = ctx;
    while (!atomic_load(&t->started)) sched_yield();
    if (jarbox_session_reserve_worker(t->session))
        jarbox_session_worker_done(t->session);
    if (jarbox_session_reserve_callback(t->session))
        jarbox_session_callback_done(t->session);
    return NULL;
}
int main(void) {
    JarBoxSession *s = jarbox_session_create((void *)(uintptr_t)0x1234);
    if (!s || !jarbox_session_bind_token(s, 123)) return 1;
    Task t = {.session=s};
    pthread_t p;
    if (pthread_create(&p, NULL, callback, &t)) return 2;
    while (!atomic_load(&t.started)) sched_yield();
    jarbox_session_begin_stop(s);
    if (jarbox_session_mark_dead(s) ||
        jarbox_session_active_lease_count(s) != 1) return 3;
    atomic_store(&t.done, 1);
    pthread_join(p, NULL);
    if (!jarbox_session_mark_dead(s) ||
        jarbox_session_reserve_callback(s) ||
        jarbox_session_reserve_worker(s)) return 4;
    jarbox_session_release(s);
    for (int i = 0; i < 10000; ++i) {
        s = jarbox_session_create((void *)(uintptr_t)0x1234);
        if (!s || !jarbox_session_bind_token(s, (uint64_t)i+1)) return 5;
        Task task = {.session=s};
        if (pthread_create(&p, NULL, race, &task)) return 6;
        atomic_store(&task.started, 1);
        jarbox_session_begin_stop(s);
        pthread_join(p, NULL);
        if (jarbox_session_active_lease_count(s) ||
            jarbox_session_worker_count(s) ||
            jarbox_session_callback_count(s) ||
            !jarbox_session_mark_dead(s) ||
            jarbox_session_mark_dead(s) ||
            jarbox_session_enter_foreground(s)) return 7;
        jarbox_session_release(s);
    }
    puts("JarBoxSession lease/shutdown race: OK (10000 iterations)");
    return 0;
}
"""


class JarBoxNativeCallbackLeaseTest(unittest.TestCase):
    def test_lease_shutdown_races(self):
        cc = shutil.which("cc") or shutil.which("clang")
        if not cc:
            self.skipTest("No host compiler")
        with tempfile.TemporaryDirectory(prefix="jarbox-lease-") as td:
            source = Path(td) / "session.c"
            exe = Path(td) / "session"
            source.write_text(C, encoding="utf-8")
            cmd = [cc, "-std=c11", "-O1", "-g", "-Wall", "-Wextra",
                   "-Werror", "-pthread", "-I", str(HEADER.parent),
                   str(source), "-o", str(exe)]
            build = subprocess.run(cmd, capture_output=True, text=True, timeout=45)
            self.assertEqual(build.returncode, 0, build.stdout + build.stderr)
            run = subprocess.run([str(exe)], capture_output=True, text=True, timeout=60)
            self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
            self.assertIn("lease/shutdown race: OK", run.stdout)


if __name__ == "__main__":
    unittest.main()
