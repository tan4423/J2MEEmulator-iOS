"""Actual C gate and scene wiring; not a Metal/iOS device test."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
NATIVE = ROOT / "J2MEEmulator/NativeBridge"
C = r"""
#include "jarbox_scene_gpu_gate.h"
#include <assert.h>
#include <sched.h>
#include <stdio.h>
static JarBoxSceneGpuGate gate = JARBOX_SCENE_GPU_GATE_INITIALIZER;
static atomic_int closed;
static void *close_gate(void *unused) {
    (void)unused;
    jarbox_scene_gpu_set_active(&gate, 0);
    atomic_store(&closed, 1);
    return NULL;
}
int main(void) {
    assert(!jarbox_scene_gpu_try_begin(&gate));
    for (int i=0; i<10000; ++i) {
        jarbox_scene_gpu_set_active(&gate, 1);
        assert(jarbox_scene_gpu_try_begin(&gate));
        assert(!jarbox_scene_gpu_try_begin(&gate));
        jarbox_scene_gpu_end(&gate);
        jarbox_scene_gpu_set_active(&gate, 0);
        assert(!jarbox_scene_gpu_try_begin(&gate));
    }
    for (int i=0; i<100; ++i) {
        pthread_t t;
        atomic_store(&closed, 0);
        jarbox_scene_gpu_set_active(&gate, 1);
        assert(jarbox_scene_gpu_try_begin(&gate));
        assert(!pthread_create(&t,NULL,close_gate,NULL));
        while (jarbox_scene_gpu_is_active(&gate)) sched_yield();
        assert(!atomic_load(&closed));
        assert(!jarbox_scene_gpu_try_begin(&gate));
        jarbox_scene_gpu_end(&gate);
        assert(!pthread_join(t,NULL));
        assert(atomic_load(&closed));
        assert(!jarbox_scene_gpu_try_begin(&gate));
    }
    puts("scene GPU gate: 10000 transitions + 100 in-flight drains PASS");
}
"""
class SceneGpuGateTest(unittest.TestCase):
    def test_gate(self):
        cc = shutil.which("cc")
        if not cc:
            self.skipTest("host C compiler unavailable")
        with tempfile.TemporaryDirectory() as td:
            p, exe = Path(td)/"gate.c", Path(td)/"gate"
            p.write_text(C)
            subprocess.run([cc, "-std=c11", "-Wall", "-Wextra", "-Werror", "-pthread",
                            "-I", str(NATIVE), str(p), "-o", str(exe)], check=True, timeout=30)
            subprocess.run([str(exe)], check=True, timeout=10)

    def test_scene_wiring(self):
        s = (NATIVE/"j2me_render.m").read_text()
        self.assertEqual(s.count("[command commit];"), 2)
        for name in ("static NSString *treo_run_metal_replay(void) {",
                     "static int treo_live_render(RenderContext *rc, TreoLiveRun *run) {"):
            body = s.split(name,1)[1].split("\n}",1)[0]
            self.assertLess(body.index("jarbox_scene_gpu_try_begin(&g_scene_gpu_gate)"),
                            body.index("[command commit];"))
            self.assertLess(body.index("[command commit];"), body.index("[command waitUntilCompleted];"))
            self.assertIn("[command waitUntilCompleted];\n", body)
            self.assertIn("jarbox_scene_gpu_end(&g_scene_gpu_gate);",
                          body.split("[command waitUntilCompleted];",1)[1])
        scene = (ROOT/"J2MEEmulator/SceneDelegate.swift").read_text()
        for name in ("sceneWillResignActive", "sceneDidEnterBackground", "sceneDidDisconnect"):
            body = scene.split("func "+name+"(",1)[1].split("\n    }",1)[0]
            self.assertIn("j2me_render_set_2d_scene_active(0)", body)
        active = scene.split("func sceneDidBecomeActive(",1)[1].split("\n    }",1)[0]
        self.assertIn("j2me_render_set_2d_scene_active(1)", active)
        self.assertIn("endSceneBackgroundTreo()", active)
        vc = (ROOT/"J2MEEmulator/UI/GameViewController.swift").read_text()
        start = vc.split("func beginSceneBackgroundTreo() {",1)[1].split("\n    }",1)[0]
        end = vc.split("func endSceneBackgroundTreo() {",1)[1].split("\n    }",1)[0]
        for guard in ("sceneBackgroundTreoToken == 0", "ownsVisibleGameSession()",
                      "jvm_bridge_is_2d_running_for_token", "treo_mode_for_token(gameSessionToken) == 0"):
            self.assertIn(guard,start)
        self.assertIn("token == gameSessionToken",end)
        self.assertIn("!parkedTreoActive",end)
        self.assertIn("treo_park_end_for_token(token)",end)

if __name__ == "__main__":
    unittest.main()
