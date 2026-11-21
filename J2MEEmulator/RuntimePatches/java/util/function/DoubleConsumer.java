/* SPDX-License-Identifier: MIT */
package java.util.function;

/** Java 8 DoubleConsumer: primitive callback and sequential composition. */
public interface DoubleConsumer {
    void accept(double value);

    default DoubleConsumer andThen(final DoubleConsumer after) {
        if (after == null) throw new NullPointerException("after");
        final DoubleConsumer before = this;
        return new DoubleConsumer() {
            public void accept(double value) {
                before.accept(value);
                after.accept(value);
            }
        };
    }
}
