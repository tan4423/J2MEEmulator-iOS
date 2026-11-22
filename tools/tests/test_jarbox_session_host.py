"""Host-level session lifecycle and worker lease regression.
Production header is compiled as C11 on the host; no iOS/JVM claim.
"""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SESSION = ROOT / "J2MEEmulator/minijvm/jvm/jarbox_session.h"

C = r"""
#include <stdint.h>
#include <pthread.h>
#include <sched.h>
#include <stdatomic.h>
#include <stdio.h>
#include "jarbox_session.h"
typedef struct {
    JarBoxSession *session;
    atomic_int running, finish;
    int ok;
} Worker;
static void *work(void *ptr) {
    Worker *w = (Worker *)ptr;
    w->ok = jarbox_session_phase(w->session) >= JARBOX_SESSION_STARTING;
    atomic_store(&w->running, 1);
    while (!atomic_load(&w->finish)) sched_yield();
    jarbox_session_worker_done(w->session);
    return NULL;
}
int main(void) {
    JarBoxSession *a = jarbox_session_create((void *)(uintptr_t)0x1234);
    JarBoxSession *b = jarbox_session_create((void *)(uintptr_t)0x1234);
    if (!a || !b) return 1;
    if (!jarbox_session_bind_token(a, 101) ||
        !jarbox_session_bind_token(b, 102) ||
        jarbox_session_bind_token(a, 103)) return 2;
    if (!jarbox_session_enter_foreground(a) ||
        !jarbox_session_enter_foreground(b) || !jarbox_session_park(a)) return 3;
    jarbox_treo_mode_set(&a->treo_state, 8);
    jarbox_treo_smart_set(&a->treo_state, 1);
    if (jarbox_treo_smart_period(&a->treo_state) != 2000 ||
        jarbox_treo_smart_period(&b->treo_state) != 500) return 12;
    Worker wa = {.session = a};
    if (!jarbox_session_reserve_worker(a)) return 4;
    pthread_t t;
    if (pthread_create(&t, NULL, work, &wa)) return 5;
    while (!atomic_load(&wa.running)) sched_yield();
    jarbox_session_begin_stop(a);
    if (jarbox_session_reserve_worker(a) || jarbox_session_mark_dead(a)) return 6;
    if (!jarbox_session_reserve_worker(b)) return 7;
    atomic_store(&wa.finish, 1);
    pthread_join(t, NULL);
    if (!wa.ok || jarbox_session_worker_count(a) ||
        !jarbox_session_mark_dead(a)) return 8;
    if (jarbox_session_enter_foreground(a)) return 9;
    if (jarbox_session_phase(b) != JARBOX_SESSION_FOREGROUND) return 10;
    jarbox_session_worker_done(b);
    jarbox_session_begin_stop(b);
    if (!jarbox_session_mark_dead(b)) return 11;
    jarbox_session_release(a);
    jarbox_session_release(b);
    puts("JarBoxSession host model: OK (two sessions, park A, stop A and keep B)");
    return 0;
}
"""
class JarBoxSessionHostTest(unittest.TestCase):
    def test_two_owner_generations_and_worker_lifetime(self):
        cc = shutil.which("cc") or shutil.which("clang")
        if not cc:
            self.skipTest("host C compiler unavailable")
        with tempfile.TemporaryDirectory(prefix="jarbox-session-") as td:
            p = Path(td) / "session.c"
            exe = Path(td) / "session"
            p.write_text(C, encoding="utf-8")
            build = subprocess.run(
                [cc, "-std=c11", "-Wall", "-Wextra", "-Werror", "-O1",
                 "-pthread", "-I", str(SESSION.parent), str(p), "-o", str(exe)],
                capture_output=True, text=True, timeout=45)
            self.assertEqual(build.returncode, 0, build.stdout + build.stderr)
            run = subprocess.run([str(exe)], capture_output=True, text=True,
                                 timeout=25)
            self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
            self.assertIn("JarBoxSession host model: OK", run.stdout)

if __name__ == "__main__":
    unittest.main()
