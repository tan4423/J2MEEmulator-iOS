"""Read-only bytecode profile tests, against real Java 8, 11, 17 classfiles."""
import subprocess
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from jar_bytecode_profile import parse_class_profile, profile_jar, FormatError


class JarBytecodeProfileTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="jarbox-bytecode-")
        self.addCleanup(self.tmp.cleanup)
        self.path = Path(self.tmp.name)

    def compile(self, version, source):
        src = self.path / "Example.java"
        src.write_text(source)
        dest = self.path / f"classes{version}"
        dest.mkdir()
        subprocess.run(["javac", "--release", str(version), "-d", str(dest), str(src)],
                       check=True, capture_output=True, text=True)
        jar = self.path / f"j{version}.jar"
        with zipfile.ZipFile(jar, "w") as z:
            for file in dest.rglob("*.class"):
                z.write(file, file.relative_to(dest).as_posix())
        return jar

    def test_version_and_dynamic_features(self):
        j8 = self.compile(8, "public class Example { public Runnable f(){return () -> {}; }}")
        p8 = profile_jar(j8)
        self.assertEqual(p8["max_base_major"], 52)
        self.assertEqual(p8["minimum_base_java_release"], "8")
        self.assertFalse(p8["has_post_java8_base_classfile"])
        self.assertIn("invokedynamic_constant", p8["feature_class_counts"])
        j11 = self.compile(11, 'public class Example { public String f(int n) {return "value="+n;} }')
        p11 = profile_jar(j11)
        self.assertEqual(p11["max_base_major"], 55)
        self.assertTrue(p11["has_post_java8_base_classfile"])
        self.assertIn("invokedynamic_constant", p11["feature_class_counts"])
        j17 = self.compile(17, "public record Example(int x) {}")
        p17 = profile_jar(j17)
        self.assertEqual(p17["max_base_major"], 61)
        self.assertIn("attribute_Record", p17["feature_class_counts"])

    def test_multi_release_separation(self):
        a = self.compile(8, "public class Example {}")
        with zipfile.ZipFile(a) as archive:
            raw = archive.read("Example.class")
        mod = self.path / "multi.jar"
        with zipfile.ZipFile(mod, "w") as archive:
            archive.writestr("META-INF/MANIFEST.MF",
                             "Manifest-Version: 1.0\r\nMulti-Release: true\r\n\r\n")
            archive.writestr("Example.class", raw)
            archive.writestr("META-INF/versions/17/Example.class", raw)
        p = profile_jar(mod)
        self.assertEqual(p["base_classfile_major_histogram"], {"52": 1})
        self.assertEqual(p["multi_release_classfile_major_histogram"], {"52": 1})
        self.assertTrue(p["manifest_multi_release"])
        self.assertFalse(p["has_post_java8_base_classfile"])

    def test_invalid_and_truncated(self):
        with self.assertRaises(FormatError):
            parse_class_profile(b"wrong")
        broken = self.path / "broken.jar"
        with zipfile.ZipFile(broken, "w") as archive:
            archive.writestr("Broken.class", b"\xca\xfe\xba\xbe\x00\x00\x00\x34\x00\x02")
        report = profile_jar(broken)
        self.assertEqual(report["class_count"], 0)
        self.assertEqual(report["parse_error_count"], 1)


if __name__ == "__main__":
    unittest.main()
