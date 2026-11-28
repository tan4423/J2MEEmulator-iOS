"""Differential test for the bounded UTF-16 String.indexOf lookup table."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
import sys

ROOT = Path(__file__).resolve().parents[2]
HEADER = ROOT / "J2MEEmulator/minijvm/jvm"


class StringIndexCacheTest(unittest.TestCase):
    def test_utf16_differential(self):
        cc = shutil.which("cc") or shutil.which("gcc")
        if not cc:
            self.skipTest("C compiler unavailable")
        source = ROOT / "tools/tests/string_index_cache_host.c"
        with tempfile.TemporaryDirectory() as d:
            exe = Path(d) / "string-index-cache"
            flags = ["-std=c11", "-Wall", "-Wextra", "-Werror", "-O1", "-g",
                     "-fsanitize=address,undefined", "-fno-omit-frame-pointer"]
            if sys.platform.startswith("linux"):
                flags.append("-no-pie")
            subprocess.run([cc, *flags, "-I", str(HEADER), str(source), "-o", str(exe)],
                           check=True, timeout=60)
            subprocess.run([str(exe)], check=True, timeout=20)


if __name__ == "__main__":
    unittest.main()
