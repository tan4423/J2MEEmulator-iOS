"""Host model of per-JVM shutdown-hook root snapshots and source ordering."""
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
JVM = ROOT / "J2MEEmulator/minijvm/jvm"
PRELUDE = r'''
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
typedef int s32;
typedef void *ArrayListValue;
typedef struct { int spinlock, length; void *items[8]; } ArrayList;
typedef struct { ArrayList *runtime_refer_copy; } GcCollector;
typedef struct { GcCollector *collector; ArrayList *shutdown_hook; } MiniJVM;
static void spin_lock(int *l) { assert(!*l); *l=1; }
static void spin_unlock(int *l) { assert(*l); *l=0; }
static void *arraylist_get_value_unsafe(ArrayList *l,int i) {
    assert(i>=0 && i<l->length); return l->items[i];
}
static int fail_after=-1;
static int arraylist_push_back_unsafe(ArrayList *l,void *v) {
    if (fail_after==0) return 0;
    if (fail_after>0) --fail_after;
    assert(l->length<8); l->items[l->length++]=v;
    return 1;
}
'''
MAIN = r'''
int main(void) {
    for (int i=0;i<10000;i++) {
        int a=1,b=2,c=3;
        ArrayList ah={.length=3,.items={&a,NULL,&b}},
                  bh={.length=1,.items={&c}},ar={0},br={0};
        GcCollector ac={&ar},bc={&br};
        MiniJVM av={&ac,&ah},bv={&bc,&bh};
        assert(gc_copy_shutdown_hook_roots(&av)==0);
        assert(ar.length==2 && ar.items[0]==&a && ar.items[1]==&b);
        assert(!br.length && !ah.spinlock);
        assert(gc_copy_shutdown_hook_roots(&bv)==0);
        assert(br.length==1 && br.items[0]==&c && !bh.spinlock);
        ah.length=0; ar.length=0;
        assert(gc_copy_shutdown_hook_roots(&av)==0);
        assert(!ar.length && br.length==1);
        ah.length=3;
        fail_after=1;
        assert(gc_copy_shutdown_hook_roots(&av)==-1);
        assert(ar.length==1 && !ah.spinlock && br.length==1);
        fail_after=-1;
    }
    puts("shutdown hook root snapshot: 10000 modeled cycles PASS");
}
'''


class ShutdownHookRootsTest(unittest.TestCase):
    def test_host_root_snapshot(self):
        cc = shutil.which(os.environ.get("CC", "cc"))
        if not cc:
            self.skipTest("host C compiler unavailable")
        gc = (JVM / "garbage.c").read_text()
        a = gc.index("static s32 gc_copy_shutdown_hook_roots(")
        b = gc.index("\n}", a) + 2
        flags = ["-std=c11", "-Wall", "-Wextra", "-Werror"]
        if os.environ.get("JARBOX_HOOK_SANITIZE") == "1":
            flags += ["-g", "-O1", "-fsanitize=address,undefined",
                      "-fno-omit-frame-pointer"]
        with tempfile.TemporaryDirectory() as td:
            src = Path(td) / "hooks.c"
            exe = Path(td) / "hooks"
            src.write_text(PRELUDE + gc[a:b] + MAIN)
            subprocess.run([cc, *flags, str(src), "-o", str(exe)],
                           check=True, timeout=30)
            result = subprocess.run([str(exe)], capture_output=True,
                                    text=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn("10000 modeled cycles PASS", result.stdout)

    def test_root_retention_and_terminal_cleanup(self):
        gc = (JVM / "garbage.c").read_text()
        copy = gc.split("s32 _gc_copy_objs(MiniJVM *jvm) {", 1)[1].split("\n}", 1)[0]
        self.assertLess(copy.index("arraylist_clear("),
                        copy.index("gc_copy_shutdown_hook_roots(jvm)"))
        destroy = (JVM / "jvm.c").read_text().split("void jvm_destroy(", 1)[1]
        self.assertLess(destroy.index("thrd_join(t, NULL)"),
                        destroy.index("arraylist_remove_at(jvm->shutdown_hook, 0)"))
        self.assertLess(destroy.index("jarbox_session_active_lease_count(jvm->session) != 0"),
                        destroy.index("arraylist_clear(jvm->shutdown_hook)"))
        self.assertLess(destroy.index("arraylist_clear(jvm->shutdown_hook)"),
                        destroy.index("gc_destroy(jvm)"))
        jni = (JVM / "jni_std.c").read_text()
        add = jni.split("s32 java_lang_Runtime_addShutdownHook(", 1)[1].split("\n}", 1)[0]
        self.assertIn("if (!jthread)", add)
        self.assertLess(add.index(">= JARBOX_SESSION_STOPPING"),
                        add.index("arraylist_push_back(runtime->jvm->shutdown_hook"))


if __name__ == "__main__":
    unittest.main()
