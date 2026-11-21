/* SPDX-License-Identifier: MIT */
package java.util;

import java.util.function.Consumer;
import java.util.function.Function;
import java.util.function.Predicate;
import java.util.function.Supplier;

/**
 * Dependency-light Java 8 Optional for miniJVM / CLDC boot runtime.
 * No stream API or Java 9+ methods. Generic signatures match Java 8.
 */
public final class Optional<T> {
    private static final Optional<?> EMPTY = new Optional<Object>(null);
    private final T value;

    private Optional(T value) { this.value = value; }

    @SuppressWarnings("unchecked")
    public static <T> Optional<T> empty() { return (Optional<T>) EMPTY; }

    public static <T> Optional<T> of(T value) {
        if (value == null) throw new NullPointerException("value");
        return new Optional<T>(value);
    }

    public static <T> Optional<T> ofNullable(T value) {
        return value == null ? Optional.<T>empty() : new Optional<T>(value);
    }

    public T get() {
        if (value == null) throw new NoSuchElementException("No value present");
        return value;
    }

    public boolean isPresent() { return value != null; }

    public void ifPresent(Consumer<? super T> consumer) {
        if (value != null) consumer.accept(value);
    }

    public Optional<T> filter(Predicate<? super T> predicate) {
        if (predicate == null) throw new NullPointerException("predicate");
        if (!isPresent()) return this;
        return predicate.test(value) ? this : Optional.<T>empty();
    }

    public <U> Optional<U> map(Function<? super T, ? extends U> mapper) {
        if (mapper == null) throw new NullPointerException("mapper");
        if (!isPresent()) return Optional.<U>empty();
        return Optional.ofNullable(mapper.apply(value));
    }

    public <U> Optional<U> flatMap(Function<? super T, Optional<U>> mapper) {
        if (mapper == null) throw new NullPointerException("mapper");
        if (!isPresent()) return Optional.<U>empty();
        Optional<U> result = mapper.apply(value);
        if (result == null) throw new NullPointerException("mapper returned null");
        return result;
    }

    public T orElse(T other) { return value != null ? value : other; }

    public T orElseGet(Supplier<? extends T> supplier) {
        return value != null ? value : supplier.get();
    }

    public <X extends Throwable> T orElseThrow(Supplier<? extends X> exceptionSupplier) throws X {
        if (value != null) return value;
        throw exceptionSupplier.get();
    }

    @Override
    public boolean equals(Object other) {
        if (this == other) return true;
        if (!(other instanceof Optional)) return false;
        Object otherValue = ((Optional<?>) other).value;
        return value == otherValue || (value != null && value.equals(otherValue));
    }

    @Override
    public int hashCode() { return value == null ? 0 : value.hashCode(); }

    @Override
    public String toString() {
        return value == null ? "Optional.empty" : "Optional[" + value + "]";
    }
}
