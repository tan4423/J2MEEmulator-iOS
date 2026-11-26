"""Host native-leaf fixture and source wiring. No device or full VM claims."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
VM = ROOT / "J2MEEmulator/minijvm/jvm"
NATIVE = ROOT / "J2MEEmulator/NativeBridge"

class CharLeafTest(unittest.TestCase):
    def test_host(self):
        cc = shutil.which("cc")
        if not cc:
            self.skipTest("host C compiler unavailable")
        with tempfile.TemporaryDirectory() as td:
            exe = Path(td) / "char_leaf"
            subprocess.run([cc, "-std=c11", "-O2", "-Wall", "-Wextra", "-Werror", "-I", str(VM),
                            str(Path(__file__).with_name("char_leaf_host.c")), "-o", str(exe)],
                           check=True, timeout=45)
            subprocess.run([str(exe)], check=True, timeout=30)

    def test_guard_and_original_fallback(self):
        source = (VM / "interpreter.c").read_text()
        block = source.split("#if JARBOX_CHAR_LEAF",1)[1].split("#endif",1)[0]
        for guard in ("method->native_func==java_lang_String_charAt0", "pruntime->jvm->session",
                      "jarbox_treo_mode_get(&pruntime->jvm->session->treo_state)==1",
                      "!pruntime->jvm->jdwp_enable","!pruntime->thrd_info->is_stop",
                      "!pruntime->thrd_info->suspend_count","!treo_game_jit_enabled_fast()",
                      "jarbox_try_char_leaf(method,pruntime)", "jarbox_char_leaf_pending==64",
                      "session->treo_state.char_leaf_calls"):
            self.assertIn(guard,block)
        self.assertLess(source.index("#if JARBOX_CHAR_LEAF"),source.index("runtime = runtime_create_inl(pruntime);"))
        self.assertIn("ret = method->native_func(runtime, clazz);",source)
        native = (VM / "jni_std.c").read_text()
        self.assertIn("u16 ch = jstring_char_at(jstr, index, runtime);",native)
        self.assertIn("out->char_leaf_calls=__atomic_load_n(&session->treo_state.char_leaf_calls", (NATIVE / "jvm_bridge.c").read_text())
        self.assertIn(r"char_leaf_calls=\(slot.char_leaf_calls)", (ROOT / "J2MEEmulator/SceneDelegate.swift").read_text())
        y = (ROOT / "codemagic.yaml").read_text()
        self.assertIn('JARBOX_VM_CHAR_LEAF_EXPERIMENT: "0"', y)
        self.assertIn("char-leaf-", y)

if __name__ == "__main__":
    unittest.main()
