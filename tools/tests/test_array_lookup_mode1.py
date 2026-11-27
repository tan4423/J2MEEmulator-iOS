"""Java arithmetic differential and source wiring, not an integrated MiniJVM test."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT=Path(__file__).resolve().parents[2]
VM=ROOT/"J2MEEmulator/minijvm/jvm"
NATIVE=ROOT/"J2MEEmulator/NativeBridge"

class ArrayLookupMode1Test(unittest.TestCase):
    def test_java_index_differential(self):
        cc,javac,java=map(shutil.which,("cc","javac","java"))
        if not all((cc,javac,java)):
            self.skipTest("host C compiler and JDK required")
        here=Path(__file__).parent
        with tempfile.TemporaryDirectory() as td:
            exe=Path(td)/"array_index"
            subprocess.run([cc,"-std=c11","-O2","-Wall","-Wextra","-Werror",
                            "-I",str(VM),str(here/"array_index_host.c"),"-o",str(exe)],check=True,timeout=45)
            subprocess.run([javac,"-d",td,str(here/"ArrayIndexOracle.java")],check=True,timeout=45)
            actual=subprocess.check_output([str(exe)],timeout=30)
            expected=subprocess.check_output([java,"-cp",td,"ArrayIndexOracle"],timeout=60)
            self.assertEqual(len(actual.splitlines()),214641)
            self.assertEqual(actual,expected)

    def test_guard_and_owner_wiring(self):
        s=(VM/"interpreter.c").read_text()
        block=s.split("const int lookup_mode1=",1)[1].split("#if TREO_VM_PAINT_SAMPLE",1)[0]
        for guard in ("TREO_VM_ARRAY_LOOKUP_MODE1 && treo_paint_mode==1",
                      "jarbox_treo_nso_family_verified","TREO_VM_ARRAY_LOOKUP_LEGACY && treo_paint_mode == 8",
                      "!method->is_native","!method->is_sync","method->breakpoint == NULL",
                      "CLASS_STATUS_CLINITED","!pruntime->jvm->jdwp_enable",
                      "!pruntime->thrd_info->is_stop","!pruntime->thrd_info->suspend_count",
                      "!treo_game_jit_enabled_fast()","treo_vm_matches_array_lookup(method)",
                      "array_field->access_flags & ACC_STATIC","width_field->access_flags & ACC_STATIC",
                      "!array_field->isvolatile","!width_field->isvolatile",
                      "array->mb.arr_type_index==DATATYPE_INT && array->arr_body",
                      "method->converted_code->max_stack<=caller->max_size-used",
                      "jarbox_array_index(","caller->sp = args;",
                      "jarbox_array_lookup_pending==64","session->treo_state.array_lookup_mode1_calls"):
            self.assertIn(guard,block)
        self.assertLess(block.index("jarbox_array_index("),block.index("caller->sp = args;"))
        self.assertIn('utf8_equals_c(m->descriptor,"(II)I")',s)
        self.assertIn("TREO_VM_ARRAY_LOOKUP_DESKTOP",s)
        self.assertIn("jarbox_lab_array_lookup_enabled()",s)
        self.assertIn("jarbox_lab_deep_note(7,64)",s)
        lab=(ROOT/"tools/desktop_lab/lab_control.h").read_text()
        self.assertIn('!strcmp(req,"lookup on")',lab)
        self.assertIn('atomic_load(&sink_requested)==1',lab)
        build=(ROOT/"tools/desktop_lab/build.sh").read_text()
        self.assertIn("-DJARBOX_DESKTOP_ARRAY_LOOKUP_TEST=1",build)
        self.assertIn("-DTREO_VM_ARRAY_LOOKUP_MODE1_EXPERIMENT=1",build)
        bridge=(NATIVE/"jvm_bridge.c").read_text()
        self.assertIn("out->array_lookup_mode1_calls=__atomic_load_n(&session->treo_state.array_lookup_mode1_calls",bridge)
        self.assertIn(r"array_lookup_mode1_calls=\(slot.array_lookup_mode1_calls)",(ROOT/"J2MEEmulator/SceneDelegate.swift").read_text())
        y=(ROOT/"codemagic.yaml").read_text()
        self.assertIn('JARBOX_VM_ARRAY_LOOKUP_MODE1_EXPERIMENT: "0"',y)
        self.assertIn("array-mode1-",y)

if __name__=="__main__": unittest.main()
