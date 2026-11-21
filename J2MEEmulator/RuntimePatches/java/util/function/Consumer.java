/* SPDX-License-Identifier: MIT */
package java.util.function;

/** Java 8 Consumer with standard sequential chaining. */
public interface Consumer<T> {
    void accept(T value);

    default Consumer<T> andThen(final Consumer<? super T> after) {
        if (after == null) throw new NullPointerException("after");
        final Consumer<T> first = this;
        return new Consumer<T>() {
            public void accept(T value) {
                first.accept(value);
                after.accept(value);
            }
        };
    }
}
