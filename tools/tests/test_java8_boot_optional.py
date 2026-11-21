"""Host-JDK regression for Java 8 Optional and function boot shims.

The package is renamed only in the test fixture to avoid silently using the
host java.base implementation. No game code is loaded or executed.
"""
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
UTIL = ROOT / "J2MEEmulator" / "RuntimePatches" / "java" / "util"

JAVA_TEST = r"""
import java.util.NoSuchElementException;
import java.util.Random;
import jarbox.compat.util.Optional;
import jarbox.compat.function.*;

public class TestJava8Optional {
    private static void equal(Object a, Object b, String note) {
        if (!(a == b || (a != null && a.equals(b))))
            throw new AssertionError(note + ": " + a + " vs " + b);
    }
    private static void check(boolean ok, String note) {
        if (!ok) throw new AssertionError(note);
    }
    private static void checkValue(String text) {
        Optional<String> a = Optional.ofNullable(text);
        java.util.Optional<String> b = java.util.Optional.ofNullable(text);
        check(a.isPresent() == b.isPresent(), "presence");
        equal(a.toString(), b.toString(), "display");
        check(a.hashCode() == b.hashCode(), "hash");
        equal(a.orElse("fallback"), b.orElse("fallback"), "orElse");
        equal(a.orElseGet(new Supplier<String>() {
            public String get() { return "default"; }
        }), b.orElseGet(() -> "default"), "orElseGet");
        equal(a.map(new Function<String,Integer>() {
            public Integer apply(String x) { return x.length(); }
        }).orElse(-1), b.map(x -> x.length()).orElse(-1), "map");
        equal(a.flatMap(new Function<String,Optional<Integer>>() {
            public Optional<Integer> apply(String x) { return Optional.of(x.length()); }
        }).orElse(-1), b.flatMap(x -> java.util.Optional.of(x.length())).orElse(-1), "flatMap");
        check(a.filter(new Predicate<String>() {
            public boolean test(String x) { return x.length() % 2 == 0; }
        }).isPresent() == b.filter(x -> x.length() % 2 == 0).isPresent(), "filter");
        final int[] calls = {0};
        a.ifPresent(new Consumer<String>() { public void accept(String x) { calls[0]++; } });
        check(calls[0] == (text == null ? 0 : 1), "ifPresent");
        if (text == null) {
            try { a.get(); throw new AssertionError("empty.get"); }
            catch (NoSuchElementException expected) { }
            try { a.orElseThrow(new Supplier<IllegalStateException>() {
                public IllegalStateException get() { return new IllegalStateException("empty"); }
            }); throw new AssertionError("empty.orElseThrow"); }
            catch (IllegalStateException expected) { }
        } else equal(a.get(), b.get(), "get");
    }
    public static void main(String[] args) {
        checkValue(null); checkValue(""); checkValue("yes");
        Random random = new Random(4490);
        for (int i = 0; i < 2000; i++) {
            int size = random.nextInt(70);
            StringBuilder value = new StringBuilder();
            for (int j = 0; j < size; j++) value.append((char) ('a' + random.nextInt(26)));
            checkValue(value.toString());
        }
        Function<Integer,Integer> twice = new Function<Integer,Integer>() {
            public Integer apply(Integer x) { return x * 2; }
        };
        Function<Integer,Integer> plus = new Function<Integer,Integer>() {
            public Integer apply(Integer x) { return x + 3; }
        };
        equal(twice.compose(plus).apply(5), 16, "compose");
        equal(twice.andThen(plus).apply(5), 13, "andThen");
        check(Function.<String>identity().apply("x").equals("x"), "identity");
        final int[] calls = {0};
        Predicate<Integer> positive = new Predicate<Integer>() {
            public boolean test(Integer value) { calls[0]++; return value > 0; }
        };
        Predicate<Integer> even = new Predicate<Integer>() {
            public boolean test(Integer value) { calls[0]++; return value % 2 == 0; }
        };
        check(!positive.and(even).test(-1) && calls[0] == 1, "AND short circuit");
        calls[0] = 0;
        check(positive.or(even).test(1) && calls[0] == 1, "OR short circuit");
        check(positive.negate().test(-2), "negate");
        check(Predicate.<String>isEqual(null).test(null), "isEqual(null)");
        check(Predicate.<String>isEqual("hi").test(new String("hi")), "isEqual");
        final StringBuilder result = new StringBuilder();
        Consumer<String> first = new Consumer<String>() {
            public void accept(String value) { result.append('a'); }
        };
        Consumer<String> second = new Consumer<String>() {
            public void accept(String value) { result.append('b'); }
        };
        first.andThen(second).accept("x");
        equal(result.toString(), "ab", "andThen order");
        try { Optional.of(null); throw new AssertionError("of null"); }
        catch (NullPointerException expected) { }
        try { Optional.<String>empty().filter(null); throw new AssertionError("filter null"); }
        catch (NullPointerException expected) { }
        try { Optional.<String>empty().map(null); throw new AssertionError("map null"); }
        catch (NullPointerException expected) { }
        try { Optional.of("a").flatMap(new Function<String,Optional<String>>() {
            public Optional<String> apply(String value) { return null; }
        }); throw new AssertionError("flatMap returned null"); }
        catch (NullPointerException expected) { }
        check(Optional.empty().equals(Optional.ofNullable(null)), "empty equality");
        check(Optional.of("x").equals(Optional.of(new String("x"))), "value equality");
        System.out.println("Optional vectors: 2003; composition and null handling: OK");
    }
}
"""


class Java8OptionalTest(unittest.TestCase):
    def test_optional_and_functional(self):
        if not shutil.which("javac") or not shutil.which("java"):
            self.skipTest("JDK unavailable")
        with tempfile.TemporaryDirectory(prefix="jarbox-optional-") as directory:
            temp = Path(directory)
            java_paths = []
            for original in sorted(UTIL.rglob("*.java")):
                if original.name not in ("Optional.java", "Function.java", "Predicate.java",
                                         "Supplier.java", "Consumer.java"):
                    continue
                source = original.read_text(encoding="utf-8")
                if original.parent.name == "function":
                    source = source.replace("package java.util.function;",
                                            "package jarbox.compat.function;", 1)
                else:
                    source = source.replace("package java.util;",
                        "package jarbox.compat.util;\nimport java.util.NoSuchElementException;", 1)
                    source = source.replace("import java.util.function.",
                                            "import jarbox.compat.function.")
                local = temp / "src" / original.relative_to(UTIL)
                local.parent.mkdir(parents=True, exist_ok=True)
                local.write_text(source, encoding="utf-8")
                java_paths.append(str(local))
            self.assertEqual(len(java_paths), 5)
            main = temp / "TestJava8Optional.java"
            main.write_text(JAVA_TEST, encoding="utf-8")
            classes = temp / "classes"
            subprocess.run(["javac", "--release", "8", "-d", str(classes)] +
                           java_paths + [str(main)],
                           check=True, text=True, capture_output=True)
            subprocess.run(["java", "-cp", str(classes), "TestJava8Optional"],
                           check=True, text=True, capture_output=True)
