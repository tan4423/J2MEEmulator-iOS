/* SPDX-License-Identifier: MIT */
package java.util;

import java.util.function.LongConsumer;
import java.util.function.LongSupplier;
import java.util.function.Supplier;

/** Java 8 OptionalLong value type for the miniJVM boot classpath. */
public final class OptionalLong {
    private static final OptionalLong EMPTY = new OptionalLong();

    private final boolean present;
    private final long value;

    private OptionalLong() {
        present = false;
        value = 0L;
    }

    private OptionalLong(long value) {
        present = true;
        this.value = value;
    }

    public static OptionalLong empty() { return EMPTY; }
    public static OptionalLong of(long value) { return new OptionalLong(value); }

    public long getAsLong() {
        if (!present) throw new NoSuchElementException("No value present");
        return value;
    }

    public boolean isPresent() { return present; }

    public void ifPresent(LongConsumer consumer) {
        if (present) consumer.accept(value);
    }

    public long orElse(long other) { return present ? value : other; }

    public long orElseGet(LongSupplier supplier) {
        return present ? value : supplier.getAsLong();
    }

    public <X extends Throwable> long orElseThrow(Supplier<? extends X> exceptionSupplier)
        throws X {
        if (present) return value;
        throw exceptionSupplier.get();
    }

    @Override
    public boolean equals(Object obj) {
        if (this == obj) return true;
        if (!(obj instanceof OptionalLong)) return false;
        OptionalLong other = (OptionalLong) obj;
        if (present != other.present) return false;
        return !present || (value == other.value);
    }

    @Override
    public int hashCode() {
        return present ? (int) (value ^ (value >>> 32)) : 0;
    }

    @Override
    public String toString() {
        return present ? "OptionalLong[" + value + "]" : "OptionalLong.empty";
    }
}
