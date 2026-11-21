"""Regression for Java 8 primitive Optional shims using their actual sources.

Renaming packages in an isolated host fixture ensures Java 8 reference classes
cannot silently replace JarBox's implementation during behavioral tests.
"""
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
UTIL = ROOT / "J2MEEmulator" / "RuntimePatches" / "java" / "util"

FIXTURE = r"""
import java.util.Random;
import java.util.NoSuchElementException;
import jarbox.compat.util.*;
import jarbox.compat.function.*;

public final class PrimitiveOptionalRegression {
    static void check(boolean ok, String label) {
        if (!ok) throw new AssertionError(label);
    }
    static void eq(Object left, Object right, String label) {
        check(left == right || (left != null && left.equals(right)), label);
    }
    public static void main(String[] args) {
        Random random = new Random(912111);
        for (int n=0; n<5000; n++) {
            int vi = random.nextInt();
            long vl = random.nextLong();
            double vd = Double.longBitsToDouble(random.nextLong());
            OptionalInt ai = OptionalInt.of(vi);
            java.util.OptionalInt bi = java.util.OptionalInt.of(vi);
            check(ai.getAsInt() == bi.getAsInt() && ai.hashCode() == bi.hashCode(), "int");
            eq(ai.toString(), bi.toString(), "int string");
            OptionalLong al = OptionalLong.of(vl);
            java.util.OptionalLong bl = java.util.OptionalLong.of(vl);
            check(al.getAsLong() == bl.getAsLong() && al.hashCode() == bl.hashCode(), "long");
            eq(al.toString(), bl.toString(), "long string");
            OptionalDouble ad = OptionalDouble.of(vd);
            java.util.OptionalDouble bd = java.util.OptionalDouble.of(vd);
            check(Double.doubleToLongBits(ad.getAsDouble()) ==
                  Double.doubleToLongBits(bd.getAsDouble()), "double bits");
            check(ad.hashCode() == bd.hashCode(), "double hash");
            eq(ad.toString(), bd.toString(), "double string");
        }
        for (double v : new double[] { 0.0, -0.0, Double.NaN,
                   Double.POSITIVE_INFINITY, Double.NEGATIVE_INFINITY,
                   Double.MIN_VALUE, Double.MAX_VALUE }) {
            eq(OptionalDouble.of(v).toString(), java.util.OptionalDouble.of(v).toString(), "double edge");
            check(OptionalDouble.of(v).hashCode() == java.util.OptionalDouble.of(v).hashCode(), "double edge hash");
        }
        check(!OptionalDouble.of(+0.0).equals(OptionalDouble.of(-0.0)), "signed zero");
        check(OptionalDouble.of(Double.NaN).equals(OptionalDouble.of(
            Double.longBitsToDouble(0x7ff8000000001234L))), "NaN normalization");
        check(!OptionalInt.empty().isPresent() && !OptionalLong.empty().isPresent()
           && !OptionalDouble.empty().isPresent(), "empty presence");
        eq(OptionalInt.empty().toString(), java.util.OptionalInt.empty().toString(), "empty int");
        eq(OptionalLong.empty().toString(), java.util.OptionalLong.empty().toString(), "empty long");
        eq(OptionalDouble.empty().toString(), java.util.OptionalDouble.empty().toString(), "empty double");
        check(OptionalInt.empty().orElseGet(new IntSupplier() {
            public int getAsInt() { return 3; }}) == 3, "int fallback");
        check(OptionalLong.empty().orElseGet(new LongSupplier() {
            public long getAsLong() { return 4L; }}) == 4L, "long fallback");
        check(OptionalDouble.empty().orElseGet(new DoubleSupplier() {
            public double getAsDouble() { return 5.5; }}) == 5.5, "double fallback");
        check(OptionalInt.of(2).orElseGet(new IntSupplier() {
            public int getAsInt() { throw new AssertionError("eager supplier"); }}) == 2, "lazy");
        final StringBuilder order = new StringBuilder();
        IntConsumer first = new IntConsumer() { public void accept(int n) { order.append('a'); } };
        IntConsumer second = new IntConsumer() { public void accept(int n) { order.append('b'); } };
        OptionalInt.of(7).ifPresent(first.andThen(second));
        check("ab".equals(order.toString()), "sequential callbacks");
        OptionalInt.empty().ifPresent(null);
        OptionalLong.empty().ifPresent(null);
        OptionalDouble.empty().ifPresent(null);
        try { OptionalInt.empty().getAsInt(); throw new AssertionError("empty int"); }
        catch (NoSuchElementException expected) { }
        try { OptionalLong.empty().getAsLong(); throw new AssertionError("empty long"); }
        catch (NoSuchElementException expected) { }
        try { OptionalDouble.empty().getAsDouble(); throw new AssertionError("empty double"); }
        catch (NoSuchElementException expected) { }
        try { OptionalInt.empty().orElseGet(null); throw new AssertionError("null supplier"); }
        catch (NullPointerException expected) { }
        try { OptionalDouble.empty().orElseThrow(new Supplier<IllegalStateException>() {
            public IllegalStateException get() { return new IllegalStateException("empty"); }
        }); throw new AssertionError("orElseThrow"); }
        catch (IllegalStateException expected) { }
    }
}
"""

class Java8PrimitiveOptionalTest(unittest.TestCase):
    def test_primitive_optionals_match_java8(self):
        if not shutil.which("java") or not shutil.which("javac"):
            self.skipTest("JDK unavailable")
        names = {"OptionalInt", "OptionalLong", "OptionalDouble", "Supplier",
                 "IntConsumer", "IntSupplier", "LongConsumer", "LongSupplier",
                 "DoubleConsumer", "DoubleSupplier"}
        with tempfile.TemporaryDirectory(prefix="jarbox-optional-primitive-") as temp:
            root = Path(temp)
            sources = []
            for origin in sorted(UTIL.rglob("*.java")):
                if origin.stem not in names:
                    continue
                source = origin.read_text(encoding="utf-8")
                source = source.replace("package java.util.function;",
                    "package jarbox.compat.function;", 1)
                source = source.replace("package java.util;",
                    "package jarbox.compat.util;\nimport java.util.NoSuchElementException;", 1)
                source = source.replace("import java.util.function.",
                                        "import jarbox.compat.function.")
                dest = root / "src" / origin.relative_to(UTIL)
                dest.parent.mkdir(parents=True, exist_ok=True)
                dest.write_text(source, encoding="utf-8")
                sources.append(str(dest))
            self.assertEqual(len(sources), 10)
            fixture = root / "PrimitiveOptionalRegression.java"
            fixture.write_text(FIXTURE, encoding="utf-8")
            classes = root / "classes"
            subprocess.run(["javac", "--release", "8", "-d", str(classes)] +
                           sources + [str(fixture)], check=True,
                           capture_output=True, text=True)
            subprocess.run(["java", "-cp", str(classes),
                            "PrimitiveOptionalRegression"],
                           check=True, capture_output=True, text=True)
