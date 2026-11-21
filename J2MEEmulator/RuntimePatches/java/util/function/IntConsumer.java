/* SPDX-License-Identifier: MIT */
package java.util.function;

/** Java 8 IntConsumer: primitive callback and sequential composition. */
public interface IntConsumer {
    void accept(int value);

    default IntConsumer andThen(final IntConsumer after) {
        if (after == null) throw new NullPointerException("after");
        final IntConsumer before = this;
        return new IntConsumer() {
            public void accept(int value) {
                before.accept(value);
                after.accept(value);
            }
        };
    }
}
