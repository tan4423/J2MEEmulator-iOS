"""Regression contracts for deferred external references and launch diagnostics.

These source checks ensure all interpreter first-use paths remain wired.
They do not substitute for a MiniJVM execution or iPhone regression.
"""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]
CORE = ROOT / "J2MEEmulator/minijvm/jvm"

class StartupLazyLinkingTest(unittest.TestCase):
    def test_external_resolution_preserves_caches_and_first_use(self):
        source = (CORE / "class.c").read_text()
        init = source.split("void class_clinit(", 1)[1].split("void class_clear_cached_virtualmethod(", 1)[0]
        self.assertIn("const int defer_external = !treo_game_jit_is_enabled();", init)
        self.assertEqual(init.count("if (!defer_external || utf8_equals(cmr->clsName, clazz->name))"), 2)
        self.assertEqual(init.count("cmr->virtual_methods = pairlist_create(0);"), 2)
        self.assertIn("if (defer_external && !utf8_equals(cfr->clsName, clazz->name)) continue;", init)
        vm = (CORE / "interpreter.c").read_text()
        for op in ("op_invokestatic", "op_invokespecial"):
            body = vm.split("case " + op + ": TREO_VM_HANDLER(" + op + ") {", 1)[1].split("case op_", 1)[0]
            self.assertIn("m = find_methodInfo_by_methodref(clazz, cmr->item.index, runtime);", body)
            self.assertLess(body.index("stack->sp = sp;"), body.index("m = find_methodInfo_by_methodref("))
            self.assertLess(body.index("sp = stack->sp;"), body.index("cmr->methodInfo = m;"))
            self.assertLess(body.index("cmr->methodInfo = m;"), body.index("*runtime->pc = " + op + "_fast;"))
        for op in ("op_getstatic", "op_putstatic", "op_getfield", "op_putfield"):
            body = vm.split("case " + op + ": TREO_VM_HANDLER(" + op + ") {", 1)[1].split("case op_", 1)[0]
            self.assertIn("find_fieldInfo_by_fieldref(", body)

    def test_initialization_and_empty_call_guard(self):
        vm = (CORE / "interpreter.c").read_text()
        self.assertIn("if (clazz->status < CLASS_STATUS_CLINITED) {\n        class_clinit(clazz, runtime);", vm)
        self.assertIn("if (subm->_this_class->status < CLASS_STATUS_CLINITED || subm->is_sync) return;", vm)

    def test_resource_fallback_is_vm_local_and_only_on_miss(self):
        source = (CORE / "jni_std.c").read_text()
        body = source.split("s32 com_sun_cldc_io_ResourceInputStream_open(", 1)[1].split("s32 java_lang_Class_forName(", 1)[0]
        self.assertIn("if (!buf) {", body)
        self.assertIn("classLoaders_find_by_instance(runtime->jvm, loader)", body)
        self.assertIn("buf = load_file_from_classpath(peer, path);", body)
        self.assertIn("nst_login_resource:found=%d,bytes=%d", body)

    def test_launch_and_version_diagnostics(self):
        vm = (CORE / "interpreter.c").read_text()
        self.assertIn("nst_login_npe:frame=", vm)
        # Check the cached constructor classification and its actual use.
        roles = vm.split("static u16 treo_mod_diag_roles(MethodInfo *m) {", 1)[1].split(
            "extern void jvm_bridge_note_net_trace", 1)[0]
        self.assertIn("Utf8String *cl = m->_this_class->name, *name = m->name", roles)
        self.assertIn('utf8_equals_c(cl, "GameMidlet") && utf8_equals_c(name, "<init>")', roles)
        self.assertIn("roles |= TREO_DIAG_MIDLET_CTOR;", roles)
        entry = vm.split("s32 execute_method_impl(MethodInfo *method, Runtime *pruntime) {", 1)[1]
        self.assertIn("if (treo_nso_init_for_runtime(runtime)) {", entry)
        self.assertIn("const u16 roles = treo_mod_diag_roles(method);", entry)
        self.assertIn("else if (roles & TREO_DIAG_MIDLET_CTOR) nso_init_probe = 2;", entry)
        self.assertIn("treo_nso_trace_cu_invokespecial(runtime, nso_init_probe,", entry)
        self.assertIn("nso_init_probe == 2", entry)
        runner = (ROOT / "j2me_api/src/javax/microedition/shell/MIDletRunner.java").read_text()
        for phase in range(1, 5):
            self.assertIn("NativeBridge.startupPhase(" + str(phase) + ",", runner)
        native = (ROOT / "J2MEEmulator/NativeBridge/j2me_input.c").read_text()
        self.assertIn('{CLS, "startupPhase", "(IJ)V", n_startupPhase}', native)

if __name__ == "__main__":
    unittest.main()
