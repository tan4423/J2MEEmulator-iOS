"""Host-JDK regression of the dependency-light Java 8 boot utility subset.

Sources are package-renamed solely for execution on the host JDK; the original
java.util classes are separately compiled and inspected in Codemagic's boot JAR.
"""
import pathlib
import shutil
import subprocess
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[2]
UTIL = ROOT / "J2MEEmulator/RuntimePatches/java/util"

JAVA_FIXTURE = r"""
import java.util.Arrays;
import java.util.Random;
import jarbox.compat.Base64;
import jarbox.compat.Objects;

public class TestJava8BootUtil {
    static void check(boolean ok, String msg) {
        if (!ok) throw new AssertionError(msg);
    }
    static void vector(byte[] raw) {
        check(Base64.getEncoder().encodeToString(raw).equals(
            java.util.Base64.getEncoder().encodeToString(raw)), "basic");
        check(Base64.getUrlEncoder().encodeToString(raw).equals(
            java.util.Base64.getUrlEncoder().encodeToString(raw)), "url");
        check(Base64.getEncoder().withoutPadding().encodeToString(raw).equals(
            java.util.Base64.getEncoder().withoutPadding().encodeToString(raw)), "unpadded");
        check(Base64.getMimeEncoder().encodeToString(raw).equals(
            java.util.Base64.getMimeEncoder().encodeToString(raw)), "mime");
        check(Base64.getMimeEncoder(12, new byte[] {'~', '!'}).encodeToString(raw).equals(
            java.util.Base64.getMimeEncoder(12, new byte[] {'~', '!'}).encodeToString(raw)), "mime custom");
        check(Arrays.equals(Base64.getDecoder().decode(Base64.getEncoder().encode(raw)), raw), "decode");
        check(Arrays.equals(Base64.getUrlDecoder().decode(Base64.getUrlEncoder().encode(raw)), raw), "url decode");
        check(Arrays.equals(Base64.getMimeDecoder().decode(Base64.getMimeEncoder().encode(raw)), raw), "mime decode");
        check(Arrays.equals(Base64.getDecoder().decode(
            Base64.getEncoder().withoutPadding().encode(raw)), raw), "unpadded decode");
        byte[] encoded = Base64.getEncoder().encode(raw), dst = new byte[encoded.length];
        check(Base64.getEncoder().encode(raw, dst) == encoded.length &&
            Arrays.equals(dst, encoded), "encode into dst");
        byte[] output = new byte[raw.length];
        check(Base64.getDecoder().decode(encoded, output) == raw.length &&
            Arrays.equals(output, raw), "decode into dst");
    }
    static void bad(String text) {
        try {
            Base64.getDecoder().decode(text);
            throw new AssertionError("accepted malformed Base64: " + text);
        } catch (IllegalArgumentException expected) { }
    }
    public static void main(String[] ignored) {
        Random random = new Random(1381);
        for (int n = 0; n < 256; n++) {
            byte[] bytes = new byte[n];
            random.nextBytes(bytes);
            vector(bytes);
        }
        bad("!"); bad("T"); bad("T=Q="); bad("TQ="); bad("TQ==A");
        check(Arrays.equals(Base64.getMimeDecoder().decode(" Zm9v\r\n? "),
             new byte[] {'f','o','o'}), "mime whitespace");
        check(Objects.equals(null, null) && Objects.equals("a", new String("a")), "equals");
        check(Objects.deepEquals(
            new Object[] {new int[] {1,2}, new String[] {"x"}},
            new Object[] {new int[] {1,2}, new String[] {"x"}}), "deepEquals");
        check(!Objects.deepEquals(new byte[] {1}, new byte[] {2}), "deepEquals false");
        check(Objects.hash("x", 42) == java.util.Objects.hash("x", 42), "hash");
        check(Objects.isNull(null) && Objects.nonNull("a"), "null checks");
        check("fallback".equals(Objects.toString(null, "fallback")), "toString");
        check("ok".equals(Objects.requireNonNull("ok")), "nonNull");
        check(Objects.compare("a", "b", String::compareTo) < 0, "compare");
    }
}
"""


class Java8BootUtilTest(unittest.TestCase):
    def test_base64_objects_against_java8_reference(self):
        if not shutil.which("javac") or not shutil.which("java"):
            self.skipTest("JDK unavailable")
        with tempfile.TemporaryDirectory(prefix="jarbox-java8-") as tmp:
            base = pathlib.Path(tmp)
            sources = base / "jarbox/compat"
            sources.mkdir(parents=True)
            for cls in ("Base64", "Objects"):
                source = (UTIL / (cls + ".java")).read_text(encoding="utf-8")
                source = source.replace("package java.util;",
                                        "package jarbox.compat;\nimport java.util.Comparator;", 1)
                (sources / (cls + ".java")).write_text(source, encoding="utf-8")
            (base / "TestJava8BootUtil.java").write_text(JAVA_FIXTURE, encoding="utf-8")
            out = base / "classes"
            subprocess.run(["javac", "--release", "8", "-d", str(out),
                            str(sources / "Base64.java"),
                            str(sources / "Objects.java"),
                            str(base / "TestJava8BootUtil.java")],
                           check=True, capture_output=True, text=True)
            subprocess.run(["java", "-cp", str(out), "TestJava8BootUtil"],
                           check=True, capture_output=True, text=True)


if __name__ == "__main__":
    unittest.main()
