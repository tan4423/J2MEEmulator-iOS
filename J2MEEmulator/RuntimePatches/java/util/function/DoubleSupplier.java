/* SPDX-License-Identifier: MIT */
package java.util.function;

/** Java 8 primitive supplier, without boxing or fake return values. */
public interface DoubleSupplier {
    double getAsDouble();
}
