"""Startup/Canvas contracts; host Java exercises the exact initContext body."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
CANVAS = ROOT / "j2me_api/src/javax/microedition/lcdui/Canvas.java"
GAME = ROOT / "J2MEEmulator/UI/GameViewController.swift"

class DirectStartupTest(unittest.TestCase):
    def test_icon_independent_watchdog(self):
        s = GAME.read_text()
        self.assertNotIn("placeholderIconView", s)
        self.assertIn("self.gameSessionToken == launchingToken else { return }", s)
        self.assertIn("self.startupWatchdog != nil", s)
        for surface in ("canvas", "form", "list", "alert"):
            self.assertIn('finishStartupWatchdog(readySurface: "' + surface + '")', s)
        self.assertIn("startupFirstSurface", s)
        self.assertIn("deadline: .now() + 20, execute: watchdog", s)

    def test_canvas_init_single_allocation_and_rollback(self):
        javac, java = shutil.which("javac"), shutil.which("java")
        if not javac or not java:
            self.skipTest("JDK unavailable")
        s = CANVAS.read_text()
        a = s.index("    void initContext() {")
        z = s.index("\n    }", a) + len("\n    }")
        program = """
public class CanvasProbe {
    private final Object paintLock = new Object();
    long nativeContext;
    Graphics graphics;
    int width = 240, height = 320;
    static class NativeBridge {
        static int created, destroyed;
        static boolean fail;
        static long createContext(int w, int h) {
            if (fail) return 0;
            return ++created;
        }
        static void destroyContext(long id) { destroyed++; }
    }
    static class Graphics {
        static boolean fail;
        Graphics(long c, int w, int h) {
            if (fail) throw new IllegalStateException();
        }
    }
""" + s[a:z] + """
    public static void main(String[] args) throws Exception {
        CanvasProbe p = new CanvasProbe();
        NativeBridge.fail = true;
        try { p.initContext(); throw new AssertionError(); }
        catch (OutOfMemoryError expected) {}
        NativeBridge.fail = false;
        Graphics.fail = true;
        try { p.initContext(); throw new AssertionError(); }
        catch (IllegalStateException expected) {}
        if (p.nativeContext != 0 || NativeBridge.destroyed != 1) throw new AssertionError();
        Graphics.fail = false;
        Thread[] threads = new Thread[16];
        for (int i = 0; i < threads.length; i++) {
            threads[i] = new Thread(() -> { for (int j=0;j<1000;j++) p.initContext(); });
            threads[i].start();
        }
        for (Thread t : threads) t.join();
        if (NativeBridge.created != 2 || p.graphics == null || p.nativeContext != 2)
            throw new AssertionError();
    }
}
"""
        with tempfile.TemporaryDirectory() as td:
            path = Path(td) / "CanvasProbe.java"
            path.write_text(program)
            subprocess.run([javac, str(path)], check=True, timeout=30)
            subprocess.run([java, "-cp", td, "CanvasProbe"], check=True, timeout=15)

if __name__ == "__main__":
    unittest.main()
