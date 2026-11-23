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
        # jthread_run caches the session before its last Java heap access.
        # Both early-stop and normal-exit paths must return this held lease.
        self.assertGreaterEqual(src.count("jarbox_session_worker_done(held_session);"), 2)
        self.assertNotIn("thrd_exit(ret);", src)
        self.assertIn("JarBoxSession *const held_session = jvm->session;", src)
        self.assertIn("jarbox_session_phase(held_session) >= JARBOX_SESSION_STOPPING", src)
        self.assertIn("jarbox_session_phase(session) >= JARBOX_SESSION_STOPPING", src)
        self.assertIn("jarbox_session_worker_done(held_session);", src)
        # Native pthreads keep the spawning JVM's immutable token. Each
        # STOPPING/normal exit must restore its prior token before release.
        self.assertIn("jvm_bridge_push_java_thread_token(held_session->token)", src)
        self.assertEqual(src.count("jvm_bridge_pop_java_thread_token(previous_token);"), 2)

    def test_timeout_does_not_force_zombie_or_destroy_still_running_worker(self):
        src = (JVM / "jvm.c").read_text()
        self.assertIn("jarbox_session_begin_stop(jvm->session);", src)
        # The teardown barrier now covers native callbacks as well as workers.
        self.assertIn("jarbox_session_active_lease_count(jvm->session) != 0", src)
        self.assertIn("jarbox_session_worker_count(jvm->session)", src)
        self.assertIn("jarbox_session_callback_count(jvm->session)", src)
        self.assertIn("heap retained", src)
        self.assertNotIn("thread_zombie_all(jvm);", src)
        self.assertLess(src.index("jarbox_session_active_lease_count(jvm->session) != 0"),
                        src.index("gc_destroy(jvm);"))
        self.assertIn("jarbox_session_mark_dead(jvm->session)", src)
        self.assertIn("jarbox_session_release(jvm->session)", src)

    def test_live_bridge_gate_and_single_window_remain_enforced(self):
        src = BRIDGE.read_text()
        self.assertIn("JarBoxSession *session;", (JVM / "jvm.h").read_text())
        self.assertIn("jarbox_session_bind_token(", src)
        # Validate the complete park/focus ownership contract, not the
        # spelling of a VM field: native operations must run under the
        # session held by bridge_pin_running_owner(), then return the lease.
        pin = src.split("static MiniJVM *bridge_pin_running_owner(", 1)[1].split(
            "int jvm_bridge_park_session(", 1)[0]
        park = src.split("int jvm_bridge_park_session(uint64_t token) {", 1)[1].split(
            "int jvm_bridge_focus_session(", 1)[0]
        focus = src.split("int jvm_bridge_focus_session(uint64_t token) {", 1)[1].split(
            "int jvm_bridge_session_is_parked(", 1)[0]
        self.assertIn("jarbox_registry_pin_vm(&g_bridge_registry, token, held)", pin)
        self.assertIn("bridge_pin_running_owner(token, &held)", park)
        self.assertIn("(void)jarbox_session_park(held)", park)
        self.assertIn("jarbox_session_callback_done(held)", park)
        self.assertLess(park.index("jarbox_session_park(held)"),
                        park.index("jarbox_session_callback_done(held)"))
        self.assertIn("bridge_pin_running_owner(token, &held)", focus)
        self.assertIn("jarbox_session_enter_foreground(held)", focus)
        self.assertIn("jarbox_session_callback_done(held)", focus)
        self.assertLess(focus.index("jarbox_session_enter_foreground(held)"),
                        focus.index("jarbox_session_callback_done(held)"))
        self.assertIn("int jvm_bridge_supported_concurrent_sessions(void) {\n    return 1;", src)
        self.assertIn("j2me_render_stop_for_owner(destroyed_render_key)", src)

if __name__ == "__main__":
    unittest.main()
