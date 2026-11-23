"""Compile actual generation-keyed frame callback routing on a POSIX host."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT=Path(__file__).resolve().parents[2]
ROUTES=ROOT/"J2MEEmulator/NativeBridge/jarbox_flush_routes.h"
RENDER=ROOT/"J2MEEmulator/NativeBridge/j2me_render.m"
C=r"""
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include "jarbox_flush_routes.h"
static int counts[3];
static void a(void *img, int w, int h, uint64_t key) {
    if (img && w==240 && h==320 && key==101) ++counts[0];
}
static void b(void *img, int w, int h, uint64_t key) {
    if (img && w==240 && h==320 && key==102) ++counts[1];
}
static void legacy(void *img, int w, int h) {
    if (img && w==240 && h==320) ++counts[2];
}
int main(void) {
    JarBoxFlushRoutes r=JARBOX_FLUSH_ROUTES_INITIALIZER;
    JarBoxFlushLegacy l=NULL;
    JarBoxFlushOwned o=NULL;
    jarbox_flush_default_owned(&r,a);
    if (!jarbox_flush_route_bind(&r,101) ||
        jarbox_flush_route_bind(&r,101)) return 1;
    jarbox_flush_default_owned(&r,b);
    if (!jarbox_flush_route_bind(&r,102)) return 2;
    if (!jarbox_flush_route_lookup(&r,101,&l,&o) || o!=a) return 3;
    o((void*)1,240,320,101);
    if (!jarbox_flush_route_lookup(&r,102,&l,&o) || o!=b) return 4;
    o((void*)1,240,320,102);
    if (counts[0]!=1 || counts[1]!=1) return 5;
    if (!jarbox_flush_route_unbind(&r,101) ||
        jarbox_flush_route_lookup(&r,101,&l,&o) ||
        !jarbox_flush_route_lookup(&r,102,&l,&o) || o!=b) return 6;
    jarbox_flush_default_legacy(&r,legacy);
    jarbox_flush_default_owned(&r,NULL);
    if (!jarbox_flush_route_bind(&r,103) ||
        !jarbox_flush_route_lookup(&r,103,&l,&o) ||
        l!=legacy || o) return 7;
    l((void*)1,240,320);
    if (counts[2]!=1 || !jarbox_flush_route_unbind(&r,102) ||
        !jarbox_flush_route_unbind(&r,103) ||
        jarbox_flush_route_lookup(&r,103,&l,&o)) return 8;
    puts("generation flush routes: OK (A/B, stop A leaves B, reject stale)");
    return 0;
}
"""
class MultiVMFlushRoutesTest(unittest.TestCase):
    def test_per_generation_callback_routes(self):
        cc=shutil.which("cc") or shutil.which("clang")
        if not cc: self.skipTest("No POSIX compiler")
        with tempfile.TemporaryDirectory(prefix="jarbox-flush-") as td:
            src,exe=Path(td)/"flush.c",Path(td)/"flush"
            src.write_text(C,encoding="utf-8")
            proc=subprocess.run([cc,"-std=c11","-pthread","-O2","-Wall","-Wextra",
                                  "-Werror","-I",str(ROUTES.parent),str(src),"-o",str(exe)],
                                 capture_output=True,text=True,timeout=45)
            self.assertEqual(proc.returncode,0,proc.stdout+proc.stderr)
            run=subprocess.run([str(exe)],capture_output=True,text=True,timeout=20)
            self.assertEqual(run.returncode,0,run.stdout+run.stderr)
            self.assertIn("generation flush routes: OK",run.stdout)
    def test_render_bridge_uses_owner_route_and_rejects_legacy_multi(self):
        src=RENDER.read_text(encoding="utf-8")
        self.assertIn("jarbox_flush_route_bind(&g_flush_routes, owner_key)",src)
        self.assertIn("jarbox_flush_route_unbind(&g_flush_routes, owner_key)",src)
        self.assertIn("jarbox_flush_route_lookup(&g_flush_routes, callerKey",src)
        self.assertIn("legacy_flush && jvm_bridge_supported_concurrent_sessions() == 1",src)

if __name__=="__main__":
    unittest.main()
