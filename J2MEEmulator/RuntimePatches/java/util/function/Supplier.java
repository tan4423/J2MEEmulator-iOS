/* SPDX-License-Identifier: MIT */
package java.util.function;

/** Java 8 Supplier subset for miniJVM's boot runtime. */
public interface Supplier<T> {
    T get();
}
