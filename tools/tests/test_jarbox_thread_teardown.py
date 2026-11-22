"""Fail closed if JVM teardown starts freeing memory before real workers finish.

Source-level lifecycle assertions; test_jarbox_session_host.py executes the
portable production state/lease policy in a host C pthread harness.
"""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]
JVM = ROOT / "J2MEEmulator/minijvm/jvm"
BRIDGE = ROOT / "J2MEEmulator/NativeBridge/jvm_bridge.c"

class JarBoxThreadTeardownTest(unittest.TestCase):
    def test_native_worker_lease_covers_thrd_create_and_exit(self):
        src = (JVM / "jvm_util.c").read_text()
        self.assertIn("if (!jarbox_session_reserve_worker(session)) return failed;", src)
        self.assertLess(src.index("jarbox_session_reserve_worker(session)"),
                        src.index("thrd_create(&runtime->thrd_info->pthread"))
        self.assertIn("jarbox_session_worker_done(session);", src)
        self.assertIn("jarbox_session_worker_done(jvm->session);", src)
        self.assertNotIn("thrd_exit(ret);", src)

    def test_timeout_does_not_force_zombie_or_destroy_still_running_worker(self):
        src = (JVM / "jvm.c").read_text()
        self.assertIn("jarbox_session_begin_stop(jvm->session);", src)
        self.assertIn("jarbox_session_worker_count(jvm->session) != 0", src)
        self.assertIn("heap retained", src)
        self.assertNotIn("thread_zombie_all(jvm);", src)
        self.assertLess(src.index("jarbox_session_worker_count(jvm->session) != 0"),
                        src.index("gc_destroy(jvm);"))
        self.assertIn("jarbox_session_mark_dead(jvm->session)", src)
        self.assertIn("jarbox_session_release(jvm->session)", src)

    def test_live_bridge_gate_and_single_window_remain_enforced(self):
        src = BRIDGE.read_text()
        self.assertIn("JarBoxSession *session;", (JVM / "jvm.h").read_text())
        self.assertIn("jarbox_session_bind_token(", src)
        self.assertIn("jarbox_session_park(owner->session)", src)
        self.assertIn("jarbox_session_enter_foreground(owner->session)", src)
        self.assertIn("int jvm_bridge_supported_concurrent_sessions(void) {\n    return 1;", src)
        self.assertIn("j2me_render_stop_for_owner(destroyed_render_key)", src)

if __name__ == "__main__":
    unittest.main()
