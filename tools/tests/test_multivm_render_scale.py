"""Exercise extracted owner-local 3D scale accessors and launch wiring."""
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2] / "J2MEEmulator"
PRELUDE = r'''
#include <assert.h>
#include <stdio.h>
#include <limits.h>
typedef struct { int render_3d_scale; } JarBoxSession;
'''
MAIN = r'''
int main(void) {
    const int values[] = {1, 2, 3, 0, -1, INT_MIN, INT_MAX};
    assert(jarbox_session_render_scale(NULL) == 1);
    jarbox_session_configure_render_scale(NULL, 3);
    for (int i = 0; i < 10000; ++i) {
        JarBoxSession a = {0}, b = {0};
        assert(jarbox_session_render_scale(&a) == 1);
        int x = values[i % 7], y = values[(i + 1) % 7];
        jarbox_session_configure_render_scale(&a, x);
        jarbox_session_configure_render_scale(&b, y);
        assert(jarbox_session_render_scale(&a) == (x > 0 ? x : 1));
        assert(jarbox_session_render_scale(&b) == (y > 0 ? y : 1));
        jarbox_session_configure_render_scale(&b, 1);
        assert(jarbox_session_render_scale(&a) == (x > 0 ? x : 1));
    }
    puts("owner-local render scale: 10000 modeled cycles PASS");
}
'''


class MultiVMRenderScaleTest(unittest.TestCase):
    def test_owner_local_scale_accessors(self):
        cc = shutil.which(os.environ.get("CC", "cc"))
        if not cc:
            self.skipTest("host C compiler unavailable")
        header = (ROOT / "minijvm/jvm/jarbox_session.h").read_text()
        a = header.index("static inline void jarbox_session_configure_render_scale(")
        b = header.index("static inline int jarbox_session_bind_token(", a)
        flags = ["-std=c11", "-Wall", "-Wextra", "-Werror"]
        if os.environ.get("JARBOX_SCALE_SANITIZE") == "1":
            flags += ["-g", "-O1", "-fsanitize=address,undefined", "-fno-omit-frame-pointer"]
        with tempfile.TemporaryDirectory() as td:
            src = Path(td) / "scale.c"
            exe = Path(td) / "scale"
            src.write_text(PRELUDE + header[a:b] + MAIN)
            subprocess.run([cc, *flags, str(src), "-o", str(exe)], check=True, timeout=30)
            result = subprocess.run([str(exe)], capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn("10000 modeled cycles PASS", result.stdout)

    def test_launch_and_both_3d_engines_use_same_owner_config(self):
        header = (ROOT / "minijvm/jvm/jarbox_session.h").read_text()
        self.assertIn("s->render_3d_scale = 1;", header)
        bridge = (ROOT / "NativeBridge/jvm_bridge.c").read_text()
        self.assertLess(bridge.index("jarbox_session_configure_render_scale(slot->jvm->session, render_3d_scale)"),
                        bridge.index("s32 ret = jvm_init(slot->jvm,"))
        self.assertIn('snprintf(ss, sizeof(ss), "%d", jarbox_session_render_scale(slot->jvm->session))', bridge)
        self.assertIn('sys_properties_set_c(slot->jvm, "micro3d.v3.fbo.scale", ss)', bridge)
        m3g = (ROOT / "NativeBridge/m3g/j2me_m3g_jni.c").read_text()
        for method in ("bindGraphics", "setViewport", "releaseGraphics"):
            body = m3g.split("static s32 n_Graphics3D_" + method + "(", 1)[1].split("\n}", 1)[0]
            self.assertIn("jarbox_session_render_scale(runtime->jvm->session)", body)
        self.assertNotIn("g_render_3d_scale", bridge + m3g)
        self.assertIn("int jvm_bridge_supported_concurrent_sessions(void) {\n    return 2;", bridge)


if __name__ == "__main__":
    unittest.main()
