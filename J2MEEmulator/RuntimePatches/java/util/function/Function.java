/* SPDX-License-Identifier: MIT */
package java.util.function;

/** Core Java 8 Function, with composition implemented without lambdas. */
public interface Function<T, R> {
    R apply(T value);

    default <V> Function<V, R> compose(final Function<? super V, ? extends T> before) {
        if (before == null) throw new NullPointerException("before");
        final Function<T, R> current = this;
        return new Function<V, R>() {
            public R apply(V value) { return current.apply(before.apply(value)); }
        };
    }

    default <V> Function<T, V> andThen(final Function<? super R, ? extends V> after) {
        if (after == null) throw new NullPointerException("after");
        final Function<T, R> current = this;
        return new Function<T, V>() {
            public V apply(T value) { return after.apply(current.apply(value)); }
        };
    }

    static <T> Function<T, T> identity() {
        return new Function<T, T>() {
            public T apply(T value) { return value; }
        };
    }
}
