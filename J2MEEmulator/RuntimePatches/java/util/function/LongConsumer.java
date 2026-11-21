/* SPDX-License-Identifier: MIT */
package java.util.function;

/** Java 8 LongConsumer: primitive callback and sequential composition. */
public interface LongConsumer {
    void accept(long value);

    default LongConsumer andThen(final LongConsumer after) {
        if (after == null) throw new NullPointerException("after");
        final LongConsumer before = this;
        return new LongConsumer() {
            public void accept(long value) {
                before.accept(value);
                after.accept(value);
            }
        };
    }
}
