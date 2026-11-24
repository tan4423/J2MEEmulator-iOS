"""Host check of 2D-only exclusion policy; not an iOS integration test."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
import sys

ROOT = Path(__file__).resolve().parents[2]
NATIVE = ROOT / "J2MEEmulator/NativeBridge"
sys.path.insert(0, str(ROOT / "tools"))
from multivm_readiness import audit

C = r'''
#include <assert.h>
#include <stdio.h>
#include <limits.h>
#include "jarbox_2d_policy.h"
int main(void) {
    for (unsigned i = 0; i < 10000; ++i) {
        assert(!jarbox_3d_conflict(0,0,1));
        assert(!jarbox_3d_conflict(1,0,0));
        assert(jarbox_3d_conflict(1,1,0));
        assert(jarbox_3d_conflict(1,0,1));
        assert(jarbox_3d_conflict(2,0,1));
        assert(jarbox_legacy_3d_allowed(1,0)==!JARBOX_2D_ONLY_RUNTIME);
        assert(jarbox_legacy_3d_allowed(2,1)==!JARBOX_2D_ONLY_RUNTIME);
        assert(!jarbox_legacy_3d_allowed(2,0));
        assert(!jarbox_legacy_3d_allowed(0,1));
        const unsigned char a[]="\xca\xfe\xba\xbe\0javax/microedition/m3g/Graphics3D";
        const unsigned char b[]="\0com.mascotcapsule.micro3d.v3.Graphics3D";
        const unsigned char c[]="\0javax/microedition/lcdui/Canvas";
        assert(jarbox_class_mentions_3d(a,sizeof a));
        assert(jarbox_class_mentions_3d(b,sizeof b));
        assert(!jarbox_class_mentions_3d(c,sizeof c));
        assert(!jarbox_class_mentions_3d(a,4));
        assert(jarbox_class_mentions_3d(NULL,0));
    }
    printf("2D policy: 10000 cycles PASS (2D-only=%d)\n", JARBOX_2D_ONLY_RUNTIME);
}
'''

class Runtime2DPolicyTest(unittest.TestCase):
    def test_native_exclusion_policy(self):
        cc = shutil.which(os.environ.get("CC", "cc"))
        if not cc:
            self.skipTest("C compiler unavailable")
        flags = ["-std=c11", "-O1", "-Wall", "-Wextra", "-Werror"]
        if os.environ.get("JARBOX_2D_POLICY_SANITIZE") == "1":
            flags += ["-g", "-fsanitize=address,undefined"]
        with tempfile.TemporaryDirectory() as td:
            p = Path(td) / "policy.c"
            p.write_text(C)
            for mode in (0, 1):
                exe = Path(td) / ("policy" + str(mode))
                subprocess.run([cc, *flags, "-I", str(NATIVE),
                                "-DJARBOX_2D_ONLY_RUNTIME=" + str(mode),
                                str(p), "-o", str(exe)], check=True, timeout=30)
                r = subprocess.run([str(exe)], capture_output=True, text=True, timeout=10)
                self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
                self.assertIn("10000 cycles PASS", r.stdout)

    def test_bridge_registration_cleanup_and_audit(self):
        src = (NATIVE / "jvm_bridge.c").read_text()
        guard = "if (jarbox_legacy_3d_allowed((unsigned)jvm_bridge_supported_concurrent_sessions(),"
        block = src.split(guard, 1)[1].split("\n    }", 1)[0]
        self.assertIn("j2me_micro3d_gl_reg_natives(slot->jvm)", block)
        self.assertIn("j2me_m3g_reg_natives(slot->jvm)", block)
        self.assertIn("slot->legacy_3d_registered = 1", block)
        for call in ("j2me_m3g_reg_natives(", "j2me_micro3d_gl_reg_natives("):
            self.assertEqual(src.count(call), 1)
        cleanup = src.split("if (slot->legacy_3d_registered) {", 1)[1].split("\n        }", 1)[0]
        self.assertIn("j2me_m3g_cleanup();", cleanup)
        self.assertIn("slot->legacy_3d_registered = 0", cleanup)
        self.assertEqual(src.count("j2me_m3g_cleanup();"), 1)
        self.assertIn("empty->legacy_3d_registered = 0", src)
        self.assertIn("slot->exclusive_3d = exclusive != 0;", src)
        self.assertIn("if (bridge_3d_conflict_locked(exclusive))", src)
        self.assertIn("bridge_try_begin_session(bridge_jar_requires_exclusive(path), out_token)", src)
        report = audit(ROOT)
        self.assertTrue(report["2d_only_legacy_3d_exclusion_guard_present"])
        self.assertFalse(report["2d_only_runtime_validated"])
        self.assertFalse(report["concurrent_jvms_safe_to_enable"])
        self.assertFalse(report["enforced_single_active_jvm"])
        # The registry ceiling is not a guarantee of safe live JVM count.
        self.assertEqual(report["configured_session_cap"], 64)
        self.assertTrue(report["experimental_multi_session_enabled"])
        self.assertNotIn("3d_global_m3g_cleanup", report["2d_only_candidate_blockers"])
        self.assertIn("3d_global_m3g_cleanup", report["unisolated_native_blockers"])

if __name__ == "__main__":
    unittest.main()
