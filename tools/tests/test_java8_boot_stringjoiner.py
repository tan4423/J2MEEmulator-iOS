"""Java 8 StringJoiner parity, using source renamed to avoid host JDK masking."""
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SRC = ROOT / "J2MEEmulator/RuntimePatches/java/util/StringJoiner.java"

JAVA_TEST = r"""
import java.util.Random;
public final class StringJoinerRegression {
    static void eq(String a, String b, String label) {
        if (!a.equals(b)) throw new AssertionError(label+": "+a+" != "+b);
    }
    static void check(boolean flag, String label) {
        if (!flag) throw new AssertionError(label);
    }
    static void same(jarbox.compat.StringJoiner a, java.util.StringJoiner b) {
        eq(a.toString(), b.toString(), "contents");
        check(a.length() == b.length(), "length");
    }
    public static void main(String[] args) {
        Random r = new Random(17029);
        String[] texts = {null, "", "a", "b", "null", "\u03bb", "--", "multiple words"};
        String[] delims = {",", "", "/", " || "};
        String[] prefixes = {"", "[", "start"};
        String[] suffixes = {"", "]", "end"};
        for (int iteration=0; iteration<2000; iteration++) {
            String delimiter = delims[r.nextInt(delims.length)];
            String prefix = prefixes[r.nextInt(prefixes.length)];
            String suffix = suffixes[r.nextInt(suffixes.length)];
            jarbox.compat.StringJoiner ours = new jarbox.compat.StringJoiner(delimiter,prefix,suffix);
            java.util.StringJoiner jdk = new java.util.StringJoiner(delimiter,prefix,suffix);
            same(ours,jdk);
            String emptyValue = "empty:"+iteration;
            ours.setEmptyValue(emptyValue); jdk.setEmptyValue(emptyValue);
            same(ours,jdk);
            for (int n=0; n<10; n++) {
                String element = texts[r.nextInt(texts.length)];
                ours.add(element); jdk.add(element);
                same(ours,jdk);
                if (n%3==0) {
                    jarbox.compat.StringJoiner other = new jarbox.compat.StringJoiner("|", "<", ">");
                    java.util.StringJoiner otherJdk = new java.util.StringJoiner("|", "<", ">");
                    for (int i=0; i<n%4; i++) {
                        other.add(texts[i]); otherJdk.add(texts[i]);
                    }
                    ours.merge(other); jdk.merge(otherJdk);
                    same(ours,jdk);
                }
            }
            ours.merge(ours); jdk.merge(jdk);
            same(ours,jdk);
        }
        jarbox.compat.StringJoiner a = new jarbox.compat.StringJoiner("@");
        java.util.StringJoiner b = new java.util.StringJoiner("@");
        a.add(""); b.add(""); a.add(""); b.add(""); same(a,b);
        StringBuilder d = new StringBuilder(",");
        jarbox.compat.StringJoiner frozen = new jarbox.compat.StringJoiner(d);
        d.append("x"); frozen.add("a").add("b");
        eq(frozen.toString(), "a,b", "delimiter snapshot");
        try {new jarbox.compat.StringJoiner(null);throw new AssertionError("delimiter null");}
        catch (NullPointerException expected) {}
        try {a.merge(null);throw new AssertionError("merge null");}
        catch (NullPointerException expected) {}
        try {a.setEmptyValue(null);throw new AssertionError("empty null");}
        catch (NullPointerException expected) {}
    }
}
"""


class StringJoinerTest(unittest.TestCase):
    def test_reference_parity(self):
        with tempfile.TemporaryDirectory(prefix="jarbox-stringjoiner-") as temp:
            root = Path(temp)
            source = root / "jarbox/compat/StringJoiner.java"
            source.parent.mkdir(parents=True)
            source.write_text(SRC.read_text().replace("package java.util;", "package jarbox.compat;", 1))
            test = root / "StringJoinerRegression.java"
            test.write_text(JAVA_TEST)
            classes = root / "classes"
            subprocess.run(["javac", "--release", "8", "-d", str(classes), str(source), str(test)],
                           check=True, capture_output=True, text=True)
            subprocess.run(["java", "-cp", str(classes), "StringJoinerRegression"],
                           check=True, capture_output=True, text=True)


if __name__ == "__main__":
    unittest.main()
