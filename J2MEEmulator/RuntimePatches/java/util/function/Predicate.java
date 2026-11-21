/* SPDX-License-Identifier: MIT */
package java.util.function;

/** Java 8 Predicate with short-circuiting boolean composition. */
public interface Predicate<T> {
    boolean test(T value);

    default Predicate<T> and(final Predicate<? super T> other) {
        if (other == null) throw new NullPointerException("other");
        final Predicate<T> first = this;
        return new Predicate<T>() {
            public boolean test(T value) {
                return first.test(value) && other.test(value);
            }
        };
    }

    default Predicate<T> or(final Predicate<? super T> other) {
        if (other == null) throw new NullPointerException("other");
        final Predicate<T> first = this;
        return new Predicate<T>() {
            public boolean test(T value) {
                return first.test(value) || other.test(value);
            }
        };
    }

    default Predicate<T> negate() {
        final Predicate<T> first = this;
        return new Predicate<T>() {
            public boolean test(T value) { return !first.test(value); }
        };
    }

    static <T> Predicate<T> isEqual(final Object target) {
        return new Predicate<T>() {
            public boolean test(T value) {
                return target == null ? value == null : target.equals(value);
            }
        };
    }
}
