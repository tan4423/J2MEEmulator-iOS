"""Source contracts for terminal stop and pre-lookup safepoint."""
from pathlib import Path
import unittest
ROOT=Path(__file__).resolve().parents[2]
class WorkerStopExitTest(unittest.TestCase):
    def test_no_stop_resurrection(self):
        src=(ROOT/"J2MEEmulator/minijvm/jvm/jvm_util.c").read_text()
        worker=src.split("s32 jthread_run(void *para) {",1)[1].split("\n}",1)[0]
        self.assertNotIn("is_stop = 0",worker)
        self.assertLess(worker.index("check_suspend_and_pause(runtime)"),worker.index("find_instance_methodInfo_by_name("))
        exit_part=worker.split("// Normal Java Thread.exit",1)[1].split("// The worker is still native-live",1)[0]
        self.assertIn("!runtime->thrd_info->is_stop",exit_part)
        self.assertIn("jarbox_session_phase(held_session) < JARBOX_SESSION_STOPPING",exit_part)
        self.assertLess(exit_part.index("spin_lock("),exit_part.index("is_interrupt = 0"))
        self.assertLess(exit_part.index("spin_unlock("),exit_part.index("execute_method_impl("))
        self.assertIn("if (run_exit) {",exit_part)
        self.assertNotIn("is_suspend = 0",exit_part)
    def test_gc_evidence_in_background(self):
        native=ROOT/"J2MEEmulator/NativeBridge"
        bridge=(native/"jvm_bridge.c").read_text()
        self.assertIn("out->gc_aborts=__atomic_load_n(&s->treo_state.gc_worker_aborts",bridge)
        scene=(ROOT/"J2MEEmulator/SceneDelegate.swift").read_text()
        self.assertIn("gc_aborts_delta=",scene)
        self.assertIn("process_cpu_valid=",scene)
        self.assertIn("process_cpu_ns=",scene)
if __name__=="__main__":unittest.main()
