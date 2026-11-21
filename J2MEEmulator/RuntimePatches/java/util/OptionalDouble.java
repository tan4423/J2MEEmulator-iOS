/* SPDX-License-Identifier: MIT */
package java.util;

import java.util.function.DoubleConsumer;
import java.util.function.DoubleSupplier;
import java.util.function.Supplier;

/** Java 8 OptionalDouble value type for the miniJVM boot classpath. */
public final class OptionalDouble {
    private static final OptionalDouble EMPTY = new OptionalDouble();

    private final boolean present;
    private final double value;

    private OptionalDouble() {
        present = false;
        value = 0.0d;
    }

    private OptionalDouble(double value) {
        present = true;
        this.value = value;
    }

    public static OptionalDouble empty() { return EMPTY; }
    public static OptionalDouble of(double value) { return new OptionalDouble(value); }

    public double getAsDouble() {
        if (!present) throw new NoSuchElementException("No value present");
        return value;
    }

    public boolean isPresent() { return present; }

    public void ifPresent(DoubleConsumer consumer) {
        if (present) consumer.accept(value);
    }

    public double orElse(double other) { return present ? value : other; }

    public double orElseGet(DoubleSupplier supplier) {
        return present ? value : supplier.getAsDouble();
    }

    public <X extends Throwable> double orElseThrow(Supplier<? extends X> exceptionSupplier)
        throws X {
        if (present) return value;
        throw exceptionSupplier.get();
    }

    @Override
    public boolean equals(Object obj) {
        if (this == obj) return true;
        if (!(obj instanceof OptionalDouble)) return false;
        OptionalDouble other = (OptionalDouble) obj;
        if (present != other.present) return false;
        return !present || (Double.doubleToLongBits(value) == Double.doubleToLongBits(other.value));
    }

    @Override
    public int hashCode() {
        return present ? (int) (Double.doubleToLongBits(value) ^ (Double.doubleToLongBits(value) >>> 32)) : 0;
    }

    @Override
    public String toString() {
        return present ? "OptionalDouble[" + value + "]" : "OptionalDouble.empty";
    }
}
