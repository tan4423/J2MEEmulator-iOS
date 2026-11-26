"""Hot JIT flag uses exactly the same state and public ABI."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
ROOT=Path(__file__).resolve().parents[2]
CORE=ROOT/"J2MEEmulator/minijvm/jvm"
class JitFlagTest(unittest.TestCase):
    def test_flag_contract(self):
        cc=shutil.which("clang") or shutil.which("cc")
        if not cc:self.skipTest("compiler unavailable")
        h=(CORE/"jit.h").read_text()
        j=(CORE/"jit.c").read_text()
        start=h.index("#if JIT_ENABLE\nextern int treo_jit_enabled_state;")
        end=h.index("#endif",start)+len("#endif")
        getter=j.split("int treo_game_jit_is_enabled(void) { return treo_game_jit_enabled_fast(); }",1)
        self.assertEqual(len(getter),2)
        setter=j.split("void treo_game_jit_set_enabled(int enabled) { __atomic_store_n(&treo_jit_enabled_state, enabled != 0, __ATOMIC_RELAXED); }",1)
        self.assertEqual(len(setter),2)
        for enabled in (0,1):
            src=f"#define JIT_ENABLE {enabled}\n"+h[start:end]+"\n"
            if enabled:
                src+="int treo_jit_enabled_state;\n"+ "int treo_game_jit_is_enabled(void) { return treo_game_jit_enabled_fast(); }\n"+"void treo_game_jit_set_enabled(int enabled) { __atomic_store_n(&treo_jit_enabled_state, enabled != 0, __ATOMIC_RELAXED); }\n"
            else:
                src+="int treo_game_jit_is_enabled(void) { return 0; }\nvoid treo_game_jit_set_enabled(int enabled) { (void)enabled; }\n"
            src+=r"""
int main(void) {
    if (treo_game_jit_enabled_fast() || treo_game_jit_is_enabled()) return 1;
    for(int i=-50000;i<50000;i++){
        treo_game_jit_set_enabled(i%3);
        int want=JIT_ENABLE && (i%3)!=0;
        if(treo_game_jit_enabled_fast()!=want || treo_game_jit_is_enabled()!=want) return 2;
    }
    return 0;
}
"""
            with tempfile.TemporaryDirectory() as td:
                p,exe=Path(td)/"test.c",Path(td)/"test"
                p.write_text(src)
                subprocess.run([cc,"-std=c11","-O2","-Wall","-Wextra","-Werror",str(p),"-o",str(exe)],check=True,timeout=30)
                subprocess.run([str(exe)],check=True,timeout=10)
    def test_interpreter_and_public_state(self):
        i=(CORE/"interpreter.c").read_text()
        j=(CORE/"jit.c").read_text()
        # Each interpreter-only tier must refuse execution when JIT is on.
        # Keep the hot getter contract, but check the actual gate sites.
        for start, end in (
            ("const u8 int_leaf = method->treo_int_leaf_kind;", "#endif"),
            ("CodeAttribute *decoded = method->converted_code;", "#endif"),
            ("if (method->treo_ref_leaf &&", "#endif"),
            ("#if JARBOX_CHAR_LEAF", "#endif"),
            ("const int lookup_mode1=", "#if TREO_VM_ARRAY_LOOKUP_DIAG"),
        ):
            with self.subTest(tier=start):
                block = i.split(start, 1)[1].split(end, 1)[0]
                self.assertIn("!treo_game_jit_enabled_fast()", block)
                self.assertEqual(block.count("treo_game_jit_enabled_fast()"), 1)
        self.assertIn("const int treo_enabled = !jvm->jdwp_enable && treo_game_jit_enabled_fast();", i)
        # Five interpreter-only tiers plus the ordinary JIT dispatch above.
        # Keep the total check: an accidental extra hot-path read still fails.
        self.assertEqual(i.count("treo_game_jit_enabled_fast()"), 6)
        self.assertNotIn("treo_game_jit_is_enabled()",i)
        self.assertEqual(j.count("int treo_jit_enabled_state;"),1)
        self.assertIn("int treo_game_jit_is_enabled(void) { return treo_game_jit_enabled_fast(); }",j)
        self.assertIn("__atomic_store_n(&treo_jit_enabled_state, enabled != 0, __ATOMIC_RELAXED)",j)
if __name__=="__main__":unittest.main()
