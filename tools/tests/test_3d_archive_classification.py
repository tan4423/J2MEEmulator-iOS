"""Archive classification with real repository miniz and generated ZIP fixtures."""
from pathlib import Path
import os
import shutil
import subprocess
import tempfile
import unittest
import zipfile

ROOT = Path(__file__).resolve().parents[2]
NATIVE = ROOT / "J2MEEmulator/NativeBridge"
MINIZ = ROOT / "J2MEEmulator/minijvm/utils"
PRE = r'''
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <sys/stat.h>
#include "miniz.h"
#include "jarbox_2d_policy.h"
'''
MAIN = r'''
int main(int argc, char **argv) {
    if (argc != 2) return 2;
    printf("%d\n", bridge_jar_requires_exclusive(argv[1]));
    return 0;
}
'''

class ArchiveClassificationTest(unittest.TestCase):
    def test_real_zip_scanner(self):
        cc = shutil.which(os.environ.get("CC", "cc"))
        if not cc:
            self.skipTest("host C compiler unavailable")
        bridge = (NATIVE / "jvm_bridge.c").read_text()
        a = bridge.index("static int bridge_jar_requires_exclusive(")
        b = bridge.index("\n}", a) + 2
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            p, exe = root / "scan.c", root / "scan"
            p.write_text(PRE + bridge[a:b] + MAIN)
            subprocess.run([cc, "-std=c11", "-D_POSIX_C_SOURCE=200809L",
                            "-O1", "-I", str(NATIVE), "-I", str(MINIZ),
                            str(p), str(MINIZ / "miniz.c"), "-o", str(exe)],
                           check=True, timeout=60)
            magic = bytes.fromhex("cafebabe")
            cases = [
                ("2d", {"A.class": magic+b"javax/microedition/lcdui/Canvas"}, 0),
                ("m3g", {"A.class": magic+b"javax/microedition/m3g/Graphics3D"}, 1),
                ("mascot", {"A.class": magic+b"com.mascotcapsule.micro3d.v3.Graphics3D"}, 1),
                ("empty", {"data.txt": b"abc"}, 1),
                ("bad", {"A.class": b"bad!"}, 1),
                ("nested", {"A.class": magic+b"Canvas", "nested.JAR": b"zip"}, 1),
                ("large", {"A.class": magic+b"x"*(2*1024*1024)}, 1),
                ("long-name", {"A.class": magic+b"Canvas", "x"*10240+".class": magic+b"Canvas"}, 1),
            ]
            for name, entries, expected in cases:
                with self.subTest(name=name):
                    jar = root / (name + ".jar")
                    with zipfile.ZipFile(jar, "w", compression=zipfile.ZIP_DEFLATED) as z:
                        for key, data in entries.items():
                            z.writestr(key, data)
                    result = subprocess.run([str(exe), str(jar)], check=True,
                                            text=True, capture_output=True, timeout=10)
                    self.assertEqual(result.stdout.strip(), str(expected))
            result = subprocess.run([str(exe), str(root / "missing.jar")],
                                    check=True, text=True, capture_output=True, timeout=10)
            self.assertEqual(result.stdout.strip(), "1")

    def test_library_checks_conflict_before_presentation(self):
        source = (ROOT / "J2MEEmulator/UI/AppsListViewController.swift").read_text()
        launch = source.split("private func launchGameTab(", 1)[1]
        self.assertLess(launch.index("jvm_bridge_3d_conflict_for_jar"),
                        launch.index("if count >= jvm_bridge_supported_concurrent_sessions()"))
        self.assertLess(launch.index("gameForTab("),
                        launch.index("jvm_bridge_3d_conflict_for_jar"))

if __name__ == "__main__":
    unittest.main()
