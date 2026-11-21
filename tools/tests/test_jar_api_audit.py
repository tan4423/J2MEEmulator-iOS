"""Regression tests for the Java classfile API auditor; no game code executed."""
import sys
from pathlib import Path
import subprocess
import tempfile
import unittest
import zipfile

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from jar_api_audit import load_jar, audit, parse_class, FormatError


class JarAuditTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="jarbox-audit-")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)

    def compile(self, name, sources, dep=None):
        src = self.root / (name + "_src")
        dest = self.root / (name + "_classes")
        src.mkdir()
        dest.mkdir()
        paths = []
        for file, code in sources.items():
            p = src / file
            p.parent.mkdir(parents=True, exist_ok=True)
            p.write_text(code)
            paths.append(str(p))
        cmd = ["javac", "--release", "8", "-d", str(dest)]
        if dep:
            cmd.extend(["-cp", str(dep)])
        subprocess.run(cmd + paths, check=True, capture_output=True, text=True)
        jar = self.root / (name + ".jar")
        with zipfile.ZipFile(jar, "w") as archive:
            for p in dest.rglob("*.class"):
                archive.write(p, p.relative_to(dest).as_posix())
        return jar, dest

    def test_missing_class_from_field_descriptor(self):
        j, _ = self.compile("missing", {
            "q/Missing.java": "package q; public class Missing {}",
            "g/Game.java": "package g; public class Game { q.Missing x; }",
        })
        with zipfile.ZipFile(j) as archive:
            raw = archive.read("g/Game.class")
        with zipfile.ZipFile(j, "w") as archive:
            archive.writestr("g/Game.class", raw)
        classes, errors = load_jar(j)
        self.assertFalse(errors)
        self.assertIn("q/Missing", audit(classes, {}, {})["missing_classes"])

    def test_missing_methods_and_fields(self):
        _, api_dir = self.compile("api", {
            "q/Api.java": "package q; public class Api { public int flag; public void run() {} }",
        })
        j, _ = self.compile("game", {
            "g/Game.java": "package g; public class Game { int f(q.Api x){x.run(); return x.flag;} }",
        }, dep=api_dir)
        new_api, _ = self.compile("newapi", {
            "q/Api.java": "package q; public class Api {}",
        })
        api, _ = load_jar(new_api)
        game, _ = load_jar(j)
        result = audit(game, api, {})
        self.assertIn("q/Api.run()V", result["missing_methods"])
        self.assertIn("q/Api.flag:I", result["missing_fields"])

    def test_inherited_members_are_supported(self):
        jar, api_dir = self.compile("api", {
            "q/Base.java": "package q; public class Base {public int flag;public void run(){}}",
            "q/Child.java": "package q; public class Child extends Base {}",
        })
        game, _ = self.compile("game", {
            "g/Game.java": "package g; public class Game {int f(q.Child x){x.run();return x.flag;}}",
        }, dep=api_dir)
        runtime, _ = load_jar(jar)
        classes, _ = load_jar(game)
        r = audit(classes, runtime, {})
        self.assertEqual(r["missing_methods"], [])
        self.assertEqual(r["missing_fields"], [])

    def test_bad_class_not_fatal_to_archive(self):
        jar, _ = self.compile("game", {
            "g/Game.java": "package g; public class Game {}",
        })
        with zipfile.ZipFile(jar, "a") as archive:
            archive.writestr("g/Broken.class", b"broken")
        classes, errors = load_jar(jar)
        self.assertIn("g/Game", classes)
        self.assertEqual(len(errors), 1)


if __name__ == "__main__":
    unittest.main()
