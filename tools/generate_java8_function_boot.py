#!/usr/bin/env python3
"""Generate the Java 8 java.util.function interfaces missing from miniJVM CLDC.

No runtime reflection, no lambda bytecode, and no placeholder results. Sources
are generated at build time for the boot JAR, excluding previously patched APIs.
"""
from __future__ import annotations
import argparse
from pathlib import Path

HEADER = """/* SPDX-License-Identifier: MIT */
/* Java 8 functional API compatibility for the JarBox boot classpath. */
package java.util.function;
"""

# Classes already in J2MEEmulator/RuntimePatches/java/util/function:
EXISTING = frozenset(("Consumer", "Function", "Predicate", "Supplier",
                      "IntConsumer", "IntSupplier", "LongConsumer", "LongSupplier",
                      "DoubleConsumer", "DoubleSupplier"))


def interface(name, params, method, extras="", parent=None):
    declaration = f"public interface {name}{params}"
    if parent:
        declaration += f" extends {parent}"
    return (HEADER + "import java.util.Comparator;\n\n" + declaration + " {\n" +
            (f"    {method};\n" if method else "") +
            ("\n" + extras.strip("\n") + "\n" if extras else "") + "}\n")


def generate():
    files = {}
    files["BiConsumer"] = interface("BiConsumer", "<T,U>", "void accept(T first, U second)", """
    default BiConsumer<T,U> andThen(final BiConsumer<? super T, ? super U> after) {
        if (after == null) throw new NullPointerException("after");
        final BiConsumer<T,U> before = this;
        return new BiConsumer<T,U>() {
            public void accept(T first, U second) {
                before.accept(first, second);
                after.accept(first, second);
            }
        };
    }
""")
    files["BiFunction"] = interface("BiFunction", "<T,U,R>", "R apply(T first, U second)", """
    default <V> BiFunction<T,U,V> andThen(final Function<? super R, ? extends V> after) {
        if (after == null) throw new NullPointerException("after");
        final BiFunction<T,U,R> before = this;
        return new BiFunction<T,U,V>() {
            public V apply(T first, U second) { return after.apply(before.apply(first,second)); }
        };
    }
""")
    files["BiPredicate"] = interface("BiPredicate", "<T,U>", "boolean test(T first, U second)", """
    default BiPredicate<T,U> and(final BiPredicate<? super T, ? super U> other) {
        if (other == null) throw new NullPointerException("other");
        final BiPredicate<T,U> left = this;
        return new BiPredicate<T,U>() {
            public boolean test(T first, U second) {
                return left.test(first,second) && other.test(first,second);
            }
        };
    }
    default BiPredicate<T,U> or(final BiPredicate<? super T, ? super U> other) {
        if (other == null) throw new NullPointerException("other");
        final BiPredicate<T,U> left = this;
        return new BiPredicate<T,U>() {
            public boolean test(T first, U second) {
                return left.test(first,second) || other.test(first,second);
            }
        };
    }
    default BiPredicate<T,U> negate() {
        final BiPredicate<T,U> before = this;
        return new BiPredicate<T,U>() {
            public boolean test(T first, U second) { return !before.test(first,second); }
        };
    }
""")
    files["UnaryOperator"] = interface("UnaryOperator", "<T>", "", """
    static <T> UnaryOperator<T> identity() {
        return new UnaryOperator<T>() { public T apply(T value) { return value; } };
    }
""", "Function<T,T>")
    files["BinaryOperator"] = interface("BinaryOperator", "<T>", "", """
    static <T> BinaryOperator<T> minBy(final Comparator<? super T> comparator) {
        if (comparator == null) throw new NullPointerException("comparator");
        return new BinaryOperator<T>() {
            public T apply(T left, T right) {
                return comparator.compare(left,right) <= 0 ? left : right;
            }
        };
    }
    static <T> BinaryOperator<T> maxBy(final Comparator<? super T> comparator) {
        if (comparator == null) throw new NullPointerException("comparator");
        return new BinaryOperator<T>() {
            public T apply(T left, T right) {
                return comparator.compare(left,right) >= 0 ? left : right;
            }
        };
    }
""", "BiFunction<T,T,T>")
    files["BooleanSupplier"] = interface("BooleanSupplier", "", "boolean getAsBoolean()")
    for p, typename in (("Int", "int"), ("Long", "long"), ("Double", "double")):
        files[p+"Function"] = interface(p+"Function", "<R>", f"R apply({typename} value)")
        files[p+"Predicate"] = interface(p+"Predicate", "", f"boolean test({typename} value)", f"""
    default {p}Predicate and(final {p}Predicate other) {{
        if (other == null) throw new NullPointerException("other");
        final {p}Predicate left = this;
        return new {p}Predicate() {{
            public boolean test({typename} value) {{ return left.test(value) && other.test(value); }}
        }};
    }}
    default {p}Predicate or(final {p}Predicate other) {{
        if (other == null) throw new NullPointerException("other");
        final {p}Predicate left = this;
        return new {p}Predicate() {{
            public boolean test({typename} value) {{ return left.test(value) || other.test(value); }}
        }};
    }}
    default {p}Predicate negate() {{
        final {p}Predicate before = this;
        return new {p}Predicate() {{
            public boolean test({typename} value) {{ return !before.test(value); }}
        }};
    }}
""")
        files[p+"UnaryOperator"] = interface(p+"UnaryOperator", "", f"{typename} applyAs{p}({typename} value)", f"""
    default {p}UnaryOperator compose(final {p}UnaryOperator before) {{
        if (before == null) throw new NullPointerException("before");
        final {p}UnaryOperator current = this;
        return new {p}UnaryOperator() {{
            public {typename} applyAs{p}({typename} value) {{
                return current.applyAs{p}(before.applyAs{p}(value));
            }}
        }};
    }}
    default {p}UnaryOperator andThen(final {p}UnaryOperator after) {{
        if (after == null) throw new NullPointerException("after");
        final {p}UnaryOperator current = this;
        return new {p}UnaryOperator() {{
            public {typename} applyAs{p}({typename} value) {{
                return after.applyAs{p}(current.applyAs{p}(value));
            }}
        }};
    }}
    static {p}UnaryOperator identity() {{
        return new {p}UnaryOperator() {{ public {typename} applyAs{p}({typename} value) {{ return value; }} }};
    }}
""")
        files[p+"BinaryOperator"] = interface(p+"BinaryOperator", "", f"{typename} applyAs{p}({typename} left, {typename} right)")
        files["Obj"+p+"Consumer"] = interface("Obj"+p+"Consumer", "<T>", f"void accept(T value, {typename} other)")
        files["To"+p+"Function"] = interface("To"+p+"Function", "<T>", f"{typename} applyAs{p}(T value)")
        files["To"+p+"BiFunction"] = interface("To"+p+"BiFunction", "<T,U>", f"{typename} applyAs{p}(T first, U second)")
    for src, stype in (("Int", "int"), ("Long", "long"), ("Double", "double")):
        for dst, dtype in (("Int", "int"), ("Long", "long"), ("Double", "double")):
            if src != dst:
                files[src+"To"+dst+"Function"] = interface(src+"To"+dst+"Function", "", f"{dtype} applyAs{dst}({stype} value)")
    if len(files) != 33 or EXISTING.intersection(files):
        raise AssertionError("Unexpected Java 8 function inventory")
    return dict(sorted(files.items()))


def write_generated(directory):
    directory.mkdir(parents=True, exist_ok=True)
    files = generate()
    for cls, source in files.items():
        (directory / (cls + ".java")).write_text(source, encoding="utf-8")
    return list(files)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    files = write_generated(args.output / "java/util/function")
    print("[JarBoxCompat] generated_java8_function_interfaces=" + str(len(files)))


if __name__ == "__main__":
    main()
