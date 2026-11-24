"""Status telemetry contracts and exact native snapshot API host test.

The host doubles test attribution and stale-token rejection, not a real JVM.
"""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
LIB = ROOT / "J2MEEmulator/UI/AppsListViewController.swift"
BRIDGE = ROOT / "J2MEEmulator/NativeBridge/jvm_bridge.c"
GC = ROOT / "J2MEEmulator/minijvm/jvm/garbage.c"


def method(source, signature):
    start = source.index(signature)
    end = source.index("\n    }", start) + len("\n    }")
    return source[start:end]


class LiveStatusTest(unittest.TestCase):
    def test_status_owns_sampling_only_while_visible_and_active(self):
        source = LIB.read_text(encoding="utf-8")
        status = source.split("final class JarBoxStatusController:", 1)[1].split(
            "class AppsListViewController:", 1)[0]
        self.assertIn('UIAction(title: "Trạng thái"', source)
        self.assertNotIn('UIAction(title: "Thông tin chung"', source)
        self.assertIn("label.textAlignment = .left", status)
        self.assertIn("Timer(timeInterval: 1, repeats: true)", status)
        self.assertIn("self.generation == current", status)
        self.assertIn("timer?.invalidate()", status)
        self.assertIn("timer = nil", status)
        self.assertIn("baseline = nil", status)
        self.assertIn("UIDevice.current.isBatteryMonitoringEnabled = previous", status)
        self.assertIn("stopSampling()", method(status, "override func viewWillDisappear("))
        self.assertIn("UIApplication.willResignActiveNotification", status)
        self.assertIn("UIScene.willDeactivateNotification", status)
        self.assertIn("viewIfLoaded?.window?.windowScene?.activationState == .foregroundActive", status)
        self.assertIn("!cpuDetail.isHidden || !ramDetail.isHidden", status)
        self.assertIn('detailLines(rows) { _ in "Chưa đo riêng" }', status)
        self.assertIn("jvm_bridge_status_heap_bytes_for_token(row.token, &bytes)", status)
        self.assertIn('row.path == lastPath ? "    " : row.game + " — "', status)
        self.assertIn("CPU App: %.1f%% (%.0f ms/s)", status)
        self.assertIn("let cpuRow = metricRow(cpuLabel, cpuButton)", status)
        self.assertIn("let ramRow = metricRow(ramLabel, ramButton)", status)
        self.assertIn("RAM App:", status)
        for removed in ("Tiết kiệm pin", "Phiên JVM trong tiến trình", "Trạng thái JVM"):
            self.assertNotIn(removed, status)
        overview = method(source, "private func showJarBoxOverview()")
        self.assertIn("let rows = statusTabRows()", overview)
        self.assertIn("jvm_bridge_session_is_active_for_token($0.token) != 0", overview)

    def test_native_snapshot_reads_existing_gc_samples_through_token_lease(self):
        gc = GC.read_text(encoding="utf-8")
        self.assertEqual(gc.count("__atomic_store_n(&collector->jarbox_status_heap_sample,"), 2)
        self.assertIn("(uint64_t)heap + 1, __ATOMIC_RELEASE", gc)
        self.assertIn("(uint64_t)heap_after + 1, __ATOMIC_RELEASE", gc)
        bridge = BRIDGE.read_text(encoding="utf-8")
        api = bridge.split("static void bridge_status_heap_snapshot(", 1)[1].split(
            "void jvm_bridge_visit_running_vm(", 1)[0]
        self.assertNotIn("gc_sum_heap(", api)
        self.assertIn("jvm_bridge_visit_running_vm_for_token(token, bridge_status_heap_snapshot", api)
        self.assertIn("__ATOMIC_ACQUIRE", api)
        cc = shutil.which("cc")
        if not cc:
            self.skipTest("host C compiler unavailable")
        prelude = r'''
#include <stdint.h>
#include <assert.h>
#include <stdio.h>
typedef struct { uint64_t jarbox_status_heap_sample; } Collector;
typedef struct { Collector *collector; } MiniJVM;
static Collector ca, cb;
static MiniJVM a = {&ca}, b = {&cb};
static uint64_t ta = 1, tb = 2;
static int jvm_bridge_visit_running_vm_for_token(uint64_t token,
        void (*visitor)(MiniJVM *, void *), void *arg) {
    if (token && token == ta) { visitor(&a, arg); return 1; }
    if (token && token == tb) { visitor(&b, arg); return 1; }
    return 0;
}
'''
        main = r'''
int main(void) {
    uint64_t bytes = 99;
    for (unsigned i = 0; i < 1000; ++i) {
        ta = 3*i+1; tb = 3*i+2;
        a.collector = &ca; b.collector = &cb;
        __atomic_store_n(&ca.jarbox_status_heap_sample, 0, __ATOMIC_RELEASE);
        __atomic_store_n(&cb.jarbox_status_heap_sample, 2001, __ATOMIC_RELEASE);
        assert(!jvm_bridge_status_heap_bytes_for_token(ta, &bytes) && bytes == 0);
        assert(jvm_bridge_status_heap_bytes_for_token(tb, &bytes) && bytes == 2000);
        __atomic_store_n(&ca.jarbox_status_heap_sample, 1, __ATOMIC_RELEASE);
        assert(jvm_bridge_status_heap_bytes_for_token(ta, &bytes) && bytes == 0);
        __atomic_store_n(&ca.jarbox_status_heap_sample, 1001, __ATOMIC_RELEASE);
        assert(jvm_bridge_status_heap_bytes_for_token(ta, &bytes) && bytes == 1000);
        assert(jvm_bridge_status_heap_bytes_for_token(tb, &bytes) && bytes == 2000);
        assert(!jvm_bridge_status_heap_bytes_for_token(ta, 0));
        uint64_t stale = ta; ta = 3*i+3;
        assert(!jvm_bridge_status_heap_bytes_for_token(stale, &bytes) && bytes == 0);
        a.collector = 0;
        assert(!jvm_bridge_status_heap_bytes_for_token(ta, &bytes) && bytes == 0);
    }
    puts("1000 scoped heap snapshot cycles OK");
    return 0;
}
'''
        with tempfile.TemporaryDirectory() as td:
            src = Path(td) / "status.c"
            exe = Path(td) / "status"
            src.write_text(prelude + "static void bridge_status_heap_snapshot(" + api + main)
            subprocess.run([cc, "-std=c11", "-Wall", "-Wextra", "-Werror", str(src), "-o", str(exe)],
                           check=True, timeout=30)
            result = subprocess.run([str(exe)], check=True, capture_output=True, text=True, timeout=10)
            self.assertIn("1000 scoped heap snapshot cycles OK", result.stdout)


if __name__ == "__main__":
    unittest.main()
