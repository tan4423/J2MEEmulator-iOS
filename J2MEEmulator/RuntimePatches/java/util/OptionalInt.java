/* SPDX-License-Identifier: MIT */
package java.util;

import java.util.function.IntConsumer;
import java.util.function.IntSupplier;
import java.util.function.Supplier;

/** Java 8 OptionalInt value type for the miniJVM boot classpath. */
public final class OptionalInt {
    private static final OptionalInt EMPTY = new OptionalInt();

    private final boolean present;
    private final int value;

    private OptionalInt() {
        present = false;
        value = 0;
    }

    private OptionalInt(int value) {
        present = true;
        this.value = value;
    }

    public static OptionalInt empty() { return EMPTY; }
    public static OptionalInt of(int value) { return new OptionalInt(value); }

    public int getAsInt() {
        if (!present) throw new NoSuchElementException("No value present");
        return value;
    }

    public boolean isPresent() { return present; }

    public void ifPresent(IntConsumer consumer) {
        if (present) consumer.accept(value);
    }

    public int orElse(int other) { return present ? value : other; }

    public int orElseGet(IntSupplier supplier) {
        return present ? value : supplier.getAsInt();
    }

    public <X extends Throwable> int orElseThrow(Supplier<? extends X> exceptionSupplier)
        throws X {
        if (present) return value;
        throw exceptionSupplier.get();
    }

    @Override
    public boolean equals(Object obj) {
        if (this == obj) return true;
        if (!(obj instanceof OptionalInt)) return false;
        OptionalInt other = (OptionalInt) obj;
        if (present != other.present) return false;
        return !present || (value == other.value);
    }

    @Override
    public int hashCode() {
        return present ? value : 0;
    }

    @Override
    public String toString() {
        return present ? "OptionalInt[" + value + "]" : "OptionalInt.empty";
    }
}
