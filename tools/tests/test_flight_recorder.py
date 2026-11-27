"""Host tests of production file journal and sampling policy."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
ROOT=Path(__file__).resolve().parents[2]
MAIN=r"""
let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
defer { try? FileManager.default.removeItem(at: root) }
let store = JarBoxFlightStore(directory: root, limit: 128)
for i in 0..<1000 {
    try store.append("event=sample seq=\(i)", durable: false)
    precondition(store.report().utf8.count <= 256)
}
precondition(store.report().contains("seq=999"))
let reopened = JarBoxFlightStore(directory: root, limit: 128)
precondition(reopened.report() == store.report())
let before = reopened.report()
do { try reopened.append(String(repeating:"x",count:129),durable:true); fatalError("oversize accepted") } catch {}
precondition(reopened.report() == before)
let scoped = JarBoxFlightStore(directory: root.appendingPathComponent("scoped"), limit: 128)
try scoped.append("run=old seq=1", durable: false)
try scoped.append("run=newer seq=2", durable: false)
try scoped.append("run=new seq=3", durable: false)
try scoped.append("run=new seq=4", durable: false)
precondition(scoped.report(run:"new") == "run=new seq=3\nrun=new seq=4\n")
precondition(scoped.report(run:"missing").isEmpty)
let sentinel = scoped.directory.appendingPathComponent("unrelated")
try Data("preserve".utf8).write(to: sentinel)
try scoped.clear()
precondition(scoped.report().isEmpty && FileManager.default.fileExists(atPath:sentinel.path))
try scoped.append("run=new seq=5", durable: false)
precondition(scoped.report(run:"new") == "run=new seq=5\n")
for _ in 0..<10000 {
    var p = JarBoxFlightPolicy()
    var a = p.observe(wall:1_000_000_000,cpu:0,valid:true,signature:"1:2:0",urgent:false)
    precondition(a.save && a.percent == nil)
    a = p.observe(wall:6_000_000_000,cpu:1_000_000_000,valid:true,signature:"1:2:0",urgent:false)
    precondition(!a.save && a.percent == 20)
    a = p.observe(wall:11_000_000_000,cpu:6_000_000_000,valid:true,signature:"1:2:0",urgent:false)
    precondition(a.save && a.percent == 100)
    a = p.observe(wall:31_000_000_000,cpu:7_000_000_000,valid:true,signature:"1:2:0",urgent:false)
    precondition(a.save && a.gap == 20_000_000_000)
    a = p.observe(wall:36_000_000_000,cpu:1,valid:true,signature:"busy",urgent:true)
    precondition(a.save && a.percent == nil)
    a = p.observe(wall:41_000_000_000,cpu:2,valid:false,signature:"busy",urgent:true)
    precondition(a.save && a.percent == nil)
}
print("1000 journal appends; 10000 sampling sequences PASS")
"""
class FlightRecorderTest(unittest.TestCase):
    def test_store_policy(self):
        swift=shutil.which("swiftc")
        if not swift:self.skipTest("Swift unavailable")
        s=(ROOT/"J2MEEmulator/SceneDelegate.swift").read_text()
        a=s.index("nonisolated final class JarBoxFlightStore")
        b=s.index("nonisolated final class JarBoxFlightRecorder",a)
        with tempfile.TemporaryDirectory() as tmp:
            p=Path(tmp)
            (p/"main.swift").write_text("import Foundation\n"+s[a:b]+MAIN)
            subprocess.run([swift,str(p/"main.swift"),"-o",str(p/"test")],check=True,timeout=60)
            subprocess.run([str(p/"test")],check=True,timeout=30)
    def test_headless_admission_export(self):
        native=(ROOT/"J2MEEmulator/NativeBridge/jvm_bridge.c").read_text()
        sampler=native.split("int jvm_bridge_flight_sample(",1)[1].split("\n}",1)[0]
        swift=(ROOT/"J2MEEmulator/SceneDelegate.swift").read_text()
        header=(ROOT/"J2MEEmulator/NativeBridge/jvm_bridge.h").read_text()
        before_unlock=sampler.split("pthread_mutex_unlock(&g_bridge_lifecycle_lock)",1)[0]
        after_pin=before_unlock.split("jarbox_session_reserve_callback(vm->session)",1)[1]
        for field in ["block_ir_seen","block_ir_plans","block_ir_shared_hits","block_ir_bytes","render_island_plans","render_island_skips","render_island_ops","render_wrapper_skips","render_island_bytes","glyph_loops","glyph_chars","glyph_draws","glyph_attempts","glyph_scope_refusals","glyph_link_refusals","glyph_data_refusals"]:
            self.assertIn("out->"+field+"=__atomic_load_n(&vm->"+field,after_pin)
            self.assertIn(field,header)
            self.assertIn(field+"=\\(slot."+field+")",swift)
        for field in ("residual_verified","residual_ready","residual_compiles","residual_calls","residual_skips","residual_deopts","residual_faults"):
            self.assertIn(field+"=\\(slot."+field+")",swift)
    def test_wiring(self):
        native=(ROOT/"J2MEEmulator/NativeBridge/jvm_bridge.c").read_text()
        sampler=native.split("int jvm_bridge_flight_sample(",1)[1].split("\n}",1)[0]
        for anchor in ("pthread_mutex_trylock(&g_bridge_lifecycle_lock)","pthread_mutex_trylock(&bridge_cpu_lock)","jarbox_session_reserve_callback(vm->session)","jarbox_session_callback_done(session)","unsigned budget=128"):
            self.assertIn(anchor,sampler)
        self.assertNotIn("pthread_mutex_lock(",sampler)
        self.assertNotIn("threadlist_",sampler)
        scene=(ROOT/"J2MEEmulator/SceneDelegate.swift").read_text()
        for anchor in ("completeUntilFirstUserAuthentication","repeating: .seconds(5)","timer?.cancel()"):
            self.assertIn(anchor,scene)
        self.assertIn('"JarBoxPerfProfile"',scene)
        self.assertIn(r"perf=\(perf)",scene)
        # Counters are sampled only under the owner lease and logged with
        # the existing bounded journal. No extra timer or per-call logging.
        for field in ("const_arith_fusions", "const_branch_fusions", "decoded_int_calls", "event_sleep_handled", "event_sleep_fallbacks", "shared_zip_probes", "shared_zip_hits", "shared_zip_negative_hits", "shared_prepared_candidates", "shared_prepared_hits", "startup_image_decodes", "startup_image_hits", "startup_image_decode_ns"):
            self.assertIn(f"out->{field}=__atomic_load_n(&session->{field},__ATOMIC_RELAXED);",sampler)
            self.assertIn(field + r"=\(slot." + field + ")",scene)
        # Existing AFK paint timing is attributed to the invoking owner.
        for field in ("afk_profile_paint_calls", "afk_profile_paint_cpu_ns", "compatible_font_reuses", "compatible_crop_hits", "compatible_crop_misses", "compatible_state_reuses", "compatible_region_culls", "qos_paint_attempts", "qos_paint_applied", "qos_paint_already_utility", "qos_paint_unrestorable", "qos_paint_errors", "qos_paint_restore_errors", "qos_paint_completed", "qos_paint_cpu_ns", "qos_paint_wall_ns", "qos_paint_over_budget", "qos_paint_backoff", "qos_original_class", "qos_observed_class", "qos_paint_normal_completed", "qos_paint_normal_wall_ns", "compatible_text_attr_reuses"):
            self.assertIn(f"out->{field}=__atomic_load_n(&session->treo_state.{field},__ATOMIC_RELAXED);",sampler)
            self.assertIn(field + r"=\(slot." + field + ")",scene)
        for stage, field in enumerate(("nso_repaint_skips", "nso_service_skips", "nso_paint_skips")):
            self.assertIn(f"out->{field}=jarbox_treo_nso_skip_count(&session->treo_state,{stage});",sampler)
            self.assertIn(field + r"=\(slot." + field + ")",scene)
        renderer=(ROOT/"J2MEEmulator/NativeBridge/j2me_render.m").read_text()
        end=renderer.split("static s32 n_profilePaintEnd(",1)[1].split("\n}",1)[0]
        afk=end.split("if (stamp < 0)",1)[1].split("return RUNTIME_STATUS_NORMAL;",1)[0]
        self.assertIn("JarBoxTreoState *state = treo_runtime_state(runtime);",afk)
        self.assertIn("__atomic_fetch_add(&state->afk_profile_paint_calls, 1, __ATOMIC_RELAXED);",afk)
        self.assertIn("__atomic_fetch_add(&state->afk_profile_paint_cpu_ns, elapsed, __ATOMIC_RELAXED);",afk)
        self.assertEqual(end.count("treo_thread_cpu_ns()"),2) # no extra clock reads
        # Manual export and park transitions force a sample even below 60%.
        export=scene.split("func export(extra:",1)[1].split("\n    }",1)[0]
        self.assertLess(export.index("self.tick(forceSave: true)"),export.index('self.write("event=manual_export")'))
        self.assertIn('case "park_entered", "park_exited":\n                self.tick(forceSave: true)',scene)
        self.assertIn("urgent: urgent || forceSave",scene)
        self.assertIn("if forceSave { return }",scene)
        self.assertIn("self.store.report(run: fullHistory ? nil : self.run)",export)
        self.assertIn("jvm_bridge_flight_gzip",scene)
        self.assertIn("try self.store.clear()",scene)
        ui=(ROOT/"J2MEEmulator/UI/GameViewController.swift").read_text()
        self.assertIn('JarBoxFlightRecorder.shared.event("park_entered", token: gameSessionToken)',ui)
        self.assertIn('JarBoxFlightRecorder.shared.event("park_exited", token: gameSessionToken)',ui)
        # Compatible mode gains exact state/font reuse, not mode-9 raster.
        font=renderer.split("static s32 n_setFont(",1)[1].split("\n}",1)[0]
        self.assertIn("rc->ownsPixels && (mode == 1 || mode == TreoAFKFastCanvas)",font)
        self.assertIn("rc->font && rc->fastFontValid",font)
        self.assertIn("rc->fastFontFace == face && rc->fastFontStyle == style && rc->fastFontSize == size",font)
        self.assertIn("rc->fastFontValid = newFont != NULL;",font)
        self.assertIn("__atomic_fetch_add(&state->compatible_font_reuses, 1, __ATOMIC_RELAXED)",font)
        self.assertIn("return treo_rc_mode(rc) == TreoAFKFastCanvas;",renderer)
        for name in ("GameViewController.swift","AppsListViewController.swift"):
            self.assertIn("JarBoxBackgroundDiagnostics.showFlight(from: self)",(ROOT/"J2MEEmulator/UI"/name).read_text())
if __name__=="__main__":unittest.main()
