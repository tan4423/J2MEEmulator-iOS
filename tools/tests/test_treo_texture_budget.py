"""Check the production texture budget arithmetic and recovery wiring."""
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
RENDER = ROOT / "J2MEEmulator/NativeBridge/j2me_render.m"


class TreoTextureBudgetTest(unittest.TestCase):
    def test_budget_boundaries(self):
        cc = shutil.which("clang") or shutil.which("cc")
        if not cc:
            self.skipTest("Host C compiler unavailable")
        src = RENDER.read_text()
        start = src.index("#define TREO_TEXTURE_OWNER_BUDGET")
        end = src.index("// Caller holds treo_live_gpu_lock", start)
        policy = src[start:end].replace("static _Atomic int treo_texture_trim_queued;", "")
        main = r"""
int main(void) {
    size_t owner = TREO_TEXTURE_OWNER_BUDGET;
    size_t total = TREO_TEXTURE_TOTAL_BUDGET;
    assert(owner == 16u * 1024u * 1024u);
    assert(total == 32u * 1024u * 1024u);
    assert(treo_texture_cache_fits(0, owner, owner));
    assert(!treo_texture_cache_fits(owner, 1, owner));
    assert(treo_texture_cache_fits(owner, owner, total));
    assert(!treo_texture_cache_fits(total, 1, total));
    assert(!treo_texture_cache_fits(0, SIZE_MAX, total));
    assert(!treo_texture_cache_fits(SIZE_MAX, 1, total));
    assert(!treo_texture_cache_fits(0, total + 1, total));
    return 0;
}
"""
        with tempfile.TemporaryDirectory() as td:
            code = Path(td) / "budget.c"
            exe = Path(td) / "budget"
            code.write_text("#include <stddef.h>\n#include <stdint.h>\n#include <assert.h>\n" + policy + main)
            subprocess.run([cc, "-std=c11", "-Wall", "-Wextra", "-Werror", str(code), "-o", str(exe)], check=True, timeout=30)
            subprocess.run([str(exe)], check=True, timeout=10)

    def test_pressure_uses_regenerable_cache_and_cpu_fallback(self):
        src = RENDER.read_text()
        texture = src.split("static id<MTLTexture> treo_live_texture(", 1)[1].split("\n}", 1)[0]
        self.assertIn("treo_texture_cache_fits(total, bytes, TREO_TEXTURE_TOTAL_BUDGET)", texture)
        self.assertIn("treo_live_trim_textures_locked()", texture)
        self.assertIn("cache = nil;", texture)
        render = src.split("static int treo_live_render(", 1)[1].split("\n}", 1)[0]
        self.assertLess(render.index("jvm_bridge_memory_state_cached()"), render.index("if (!treo_live_pipeline)"))
        self.assertIn("treo_live_trim_textures_locked();", render)
        trim = src.split("static void treo_live_trim_textures_locked(void)", 1)[1].split("\n}", 1)[0]
        self.assertNotIn("treo_live_owner_targets", trim)
        self.assertNotIn("jvm_destroy", trim)


if __name__ == "__main__":
    unittest.main()
