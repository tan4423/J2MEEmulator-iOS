"""Focused correctness tests for the Desktop q3 array lookup candidate."""
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
                            "-I",str(VM),str(here/"array_index_host.c"),"-o",str(exe)],
                           check=True,timeout=45)
            subprocess.run([javac,"-d",td,str(here/"ArrayIndexOracle.java")],
                           check=True,timeout=45)
            actual=subprocess.check_output([str(exe)],timeout=30)
            expected=subprocess.check_output([java,"-cp",td,"ArrayIndexOracle"],timeout=60)
            self.assertEqual(len(actual.splitlines()),214641)
            self.assertEqual(actual,expected)

    def test_desktop_q3_leaf_guards_and_fallback(self):
        headless=(VM/"jarbox_desktop_headless.h").read_text()
        kind=headless.split("static unsigned desktop_map_kind",1)[1].split("static FieldInfo *desktop_map_field",1)[0]
        leaf=headless.split("static int desktop_map_leaf",1)[1].split("/* Independent Desktop Logic A/B",1)[0]
        for guard in (
            "ca->code_length==17",
            "ca->exception_table_length==1",
            'jbr_eq(m->_this_class->name,"Class_hii")',
            'jbr_eq(m->descriptor,"(II)I")',
            'c[10]==0x2e&&jbr_eq(m->name,"q3")',
        ):
            self.assertIn(guard,kind)
        for guard in (
            "if(kind!=2)return 0",
            'desktop_map_field(cl,jbg_u16(c+1),"x3","[I"',
            'desktop_map_field(cl,jbg_u16(c+5),"j1","I"',
            "jarbox_lab_array_lookup_enabled()",
            "jarbox_lab_sink_level(0)!=1",
            "jarbox_array_index(",
            "args[3].rvalue=arr",
            "s->sp=args;push_int(s,value)",
        ):
            self.assertIn(guard,leaf)
        self.assertIn("if(desktop_map_leaf(method,pruntime)||desktop_graphics_leaf(method,pruntime))",
                      (VM/"interpreter.c").read_text())
        interpreter=(VM/"interpreter.c").read_text()
        desktop=interpreter.split("#if TREO_VM_ARRAY_LOOKUP_DESKTOP",1)[1].split("#else",1)[0]
        self.assertIn("const int lookup_mode1=0",desktop)
        self.assertIn("const int lookup_legacy=0",desktop)

    def test_lab_controls_and_production_default(self):
        lab=(ROOT/"tools/desktop_lab/lab_control.h").read_text()
        self.assertIn('!strcmp(req,"lookup on")',lab)
        self.assertIn("atomic_load(&sink_requested)==1",lab)
        build=(ROOT/"tools/desktop_lab/build.sh").read_text()
        self.assertIn("-DJARBOX_DESKTOP_ARRAY_LOOKUP_TEST=1",build)
        self.assertIn("-DTREO_VM_ARRAY_LOOKUP_MODE1_EXPERIMENT=1",build)
        y=(ROOT/"codemagic.yaml").read_text()
        self.assertIn('JARBOX_VM_ARRAY_LOOKUP_MODE1_EXPERIMENT: "0"',y)

if __name__=="__main__":
    unittest.main()
