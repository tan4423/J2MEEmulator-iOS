"""Exercise the production bootstrap block against injected missing classes.

Class loading and Java heap operations are mocked; not a full JVM test.
"""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
JVM = ROOT / 'J2MEEmulator/minijvm/jvm/jvm.c'
PRELUDE = r'''
#include <assert.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
typedef int s32;
typedef const char *Utf8String;
typedef int JClass;
typedef int Instance;
typedef struct { int type; Instance *jthread; } Info;
typedef struct { Info *thrd_info; } Runtime;
typedef struct { Runtime *runtime; void *objs_holder; int exit_flag; } Collector;
typedef struct { Collector *collector; } MiniJVM;
#define THREAD_TYPE_NORMAL 1
#define STR_CLASS_JAVA_LANG_INTEGER "Integer"
#define STR_CLASS_JAVA_LANG_THREAD "Thread"
#define STR_CLASS_SUN_MISC_LAUNCHER "Launcher"
#define STR_CLASS_JAVA_LANG_INTERRUPTED "InterruptedException"
#define jvm_printf printf
static int missing, loaded, strings, runtimes, moved, instances;
static JClass classes[4];
static Instance objects[2];
static Runtime *runtime_create(MiniJVM *jvm) {
    (void)jvm; ++runtimes;
    Runtime *r = calloc(1, sizeof(*r));
    r->thrd_info = calloc(1, sizeof(Info));
    return r;
}
static Utf8String *utf8_create_c(const char *s) {
    ++strings; Utf8String *u = malloc(sizeof(*u)); *u = s; return u;
}
static void utf8_clear(Utf8String *u) { *u = ""; }
static void utf8_append_c(Utf8String *u, const char *s) { *u = s; }
static const char *utf8_cstr(Utf8String *u) { return *u; }
static JClass *classes_load_get_with_clinit(void *loader, Utf8String *u, Runtime *r) {
    (void)loader; assert(*u && r); ++loaded;
    return loaded == missing ? NULL : &classes[loaded - 1];
}
static JClass *classes_get_c(MiniJVM *j, void *l, const char *name) {
    (void)j; (void)l; (void)name; return missing == 2 ? NULL : &classes[1];
}
static Instance *instance_create(Runtime *r, JClass *c) {
    assert(r && c); assert(instances < 2); return &objects[instances++];
}
static void hashset_put(void *h, Instance *i) { (void)h; assert(i); }
static void utf8_destroy(Utf8String *u) { --strings; free(u); }
static void gc_move_objs_thread_2_gc(Runtime *r) { assert(r); ++moved; }
static void runtime_destroy(Runtime *r) { --runtimes; free(r->thrd_info); free(r); }
static s32 bootstrap(MiniJVM *jvm, const char *p_bootclasspath) {
'''
MAIN = r'''
    return 0;
}
int main(void) {
    for (int n = 0; n < 100; ++n) {
        for (missing = 1; missing <= 5; ++missing) {
            Info info = {0}; Runtime gc = {&info}; Collector c = {&gc, NULL, 0}; MiniJVM j = {&c};
            loaded = strings = runtimes = moved = instances = 0;
            int result = bootstrap(&j, "rt.jar");
            assert(strings == 0 && runtimes == 0 && moved == 1);
            if (missing <= 4) {
                assert(result == -1 && c.exit_flag == 1);
                assert(loaded == missing && instances == 0 && !info.jthread);
            } else {
                assert(result == 0 && !c.exit_flag && loaded == 4 && instances == 2 && info.jthread);
            }
        }
    }
    puts("bootstrap missing-class cleanup: OK");
    return 0;
}
'''


def harness(src):
    start = src.index('    // Bootstrap owns this temporary Runtime') if '    // Bootstrap owns this temporary Runtime' in src else src.index('    //init load thread, string etc')
    end = src.index('    // Start the collector only after bootstrap succeeds.', start)
    return PRELUDE + src[start:end] + MAIN


class BootstrapFailureCleanupTest(unittest.TestCase):
    def test_each_missing_required_class_releases_bootstrap_runtime(self):
        cc = shutil.which('clang') or shutil.which('cc')
        if not cc:
            self.skipTest('host C compiler unavailable')
        with tempfile.TemporaryDirectory() as td:
            c = Path(td) / 'bootstrap.c'
            exe = Path(td) / 'bootstrap'
            c.write_text(harness(JVM.read_text(encoding='utf-8')))
            subprocess.run([cc, '-std=c11', '-Wall', '-Wextra', '-Werror', '-Wno-unused-function', str(c), '-o', str(exe)], check=True, timeout=30)
            result = subprocess.run([str(exe)], capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn('bootstrap missing-class cleanup: OK', result.stdout)


if __name__ == '__main__':
    unittest.main()
