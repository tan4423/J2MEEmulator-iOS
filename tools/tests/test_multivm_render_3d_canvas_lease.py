"""3D pixel transfers must use the same generation-checked lease as 2D.

These are source-contract checks; native OpenGL/Metal and UIKit require an
iPhone. The existing C registry harness exercises real stale/foreign handle
rejection and refcount lifetime.
"""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2] / "J2MEEmulator/NativeBridge"


class MultiVMRender3DCanvasLeaseTest(unittest.TestCase):
    def test_3d_canvas_entrypoint_validates_generation_and_drains_before_borrow(self):
        src = (ROOT / "j2me_render.m").read_text()
        body = src.split("void *j2me_render_acquire_canvas(", 1)[1].split(
            "static CGImageRef treo_canvas_snapshot", 1)[0]
        self.assertIn("rc_acquire(handle, jarbox_native_heap_key_for_runtime(runtime))", body)
        self.assertIn("if (!rc) return NULL;", body)
        self.assertLess(body.index("treo_live_barrier(rc)"), body.index("*out_context = rc->ctx"))
        self.assertIn("rc_release((RenderContext *)lease)", body)

    def test_mascot_and_m3g_no_raw_canvas_pointer(self):
        for relative, functions in (
            ("j2me_micro3d_gl.m", ("n_mc3dBlitToGraphics", "n_mc3dReadCanvasPixels")),
            ("m3g/j2me_m3g_jni.c", ("n_Graphics3D_bindGraphics", "n_Graphics3D_releaseGraphics")),
        ):
            src = (ROOT / relative).read_text()
            for name in functions:
                with self.subTest(name=name):
                    body = src.split("static s32 " + name + "(", 1)[1].split("\n}\n", 1)[0]
                    self.assertNotIn("CGContextRef *ctxPtr", body)
                    self.assertIn("j2me_render_acquire_canvas(runtime,", body)
                    self.assertIn("j2me_render_release_canvas(lease);", body)

    def test_mascot_workspace_is_generation_owned(self):
        mc = (ROOT / "j2me_micro3d_gl.m").read_text()
        bridge = (ROOT / "jvm_bridge.c").read_text()
        self.assertIn("jarbox_native_heap_key_for_runtime(runtime)", mc)
        self.assertIn("g_mc3d_workspaces[@(key)]", mc)
        self.assertIn("mc3d_workspace(runtime, 1)", mc)
        self.assertIn("mc3d_workspace(runtime, 0)", mc)
        self.assertNotIn("static EAGLContext *g_mc3d_context =", mc)
        self.assertIn("[g_mc3d_workspaces removeObjectForKey:@(owner_key)]", mc)
        destroy = bridge.split("static void bridge_destroy_slot(", 1)[1].split(
            "int jvm_bridge_request_stop_for_token(", 1)[0]
        self.assertLess(destroy.index("jvm_destroy(slot->jvm)"),
                        destroy.index("j2me_micro3d_gl_cleanup_for_owner(destroyed_render_key)"))
        self.assertLess(destroy.index("j2me_micro3d_gl_cleanup_for_owner(destroyed_render_key)"),
                        destroy.index("jarbox_native_heap_unregister_key(destroyed_render_key)"))
        self.assertIn("const uint64_t destroyed_render_key = slot->native_heap_key;", destroy)
        self.assertNotIn("jarbox_native_heap_unregister_vm(", destroy)

if __name__ == "__main__":
    unittest.main()
