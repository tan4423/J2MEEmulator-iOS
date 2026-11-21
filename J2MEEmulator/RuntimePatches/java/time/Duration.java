/* SPDX-License-Identifier: MIT */
package java.time;

/**
 * Immutable second/nanosecond duration for miniJVM's Java 8 boot layer.
 * Deliberate subset: does not depend on Temporal, ChronoUnit or BigInteger.
 */
public final class Duration implements Comparable<Duration> {
    private static final long BILLION = 1000000000L;
    public static final Duration ZERO = new Duration(0, 0);
    private final long seconds;
    private final int nanos;

    private Duration(long seconds, int nanos) { this.seconds = seconds; this.nanos = nanos; }

    private static long checkedAdd(long a, long b) {
        long result = a + b;
        if (((a ^ result) & (b ^ result)) < 0) throw new ArithmeticException("long overflow");
        return result;
    }
    private static long checkedMultiply(long a, long b) {
        long result = a * b;
        if ((a != 0 && result / a != b) || (a == Long.MIN_VALUE && b == -1)) {
            throw new ArithmeticException("long overflow");
        }
        return result;
    }

    public static Duration ofSeconds(long seconds) { return ofSeconds(seconds, 0); }
    public static Duration ofSeconds(long seconds, long nanoAdjustment) {
        long secs = checkedAdd(seconds, nanoAdjustment / BILLION);
        long ns = nanoAdjustment % BILLION;
        if (ns < 0) { secs = checkedAdd(secs, -1); ns += BILLION; }
        if (secs == 0 && ns == 0) return ZERO;
        return new Duration(secs, (int) ns);
    }
    public static Duration ofMillis(long millis) {
        return ofSeconds(millis / 1000L, (millis % 1000L) * 1000000L);
    }
    public static Duration ofNanos(long nanos) {
        return ofSeconds(nanos / BILLION, nanos % BILLION);
    }
    public static Duration ofMinutes(long minutes) {
        return ofSeconds(checkedMultiply(minutes, 60L));
    }
    public static Duration ofHours(long hours) {
        return ofSeconds(checkedMultiply(hours, 3600L));
    }
    public static Duration ofDays(long days) {
        return ofSeconds(checkedMultiply(days, 86400L));
    }

    public long getSeconds() { return seconds; }
    public int getNano() { return nanos; }
    public boolean isZero() { return seconds == 0 && nanos == 0; }
    public boolean isNegative() { return seconds < 0; }

    public long toDays() { return seconds / 86400L; }
    public long toHours() { return seconds / 3600L; }
    public long toMinutes() { return seconds / 60L; }
    public long toMillis() {
        // For negative fractions Java truncates toward zero, not -infinity.
        if (seconds < 0 && nanos > 0)
            return checkedAdd(checkedMultiply(checkedAdd(seconds, 1), 1000L),
                              (nanos - BILLION) / 1000000L);
        return checkedAdd(checkedMultiply(seconds, 1000L), nanos / 1000000L);
    }
    public long toNanos() {
        if (seconds < 0 && nanos > 0)
            return checkedAdd(checkedMultiply(checkedAdd(seconds, 1), BILLION),
                              nanos - BILLION);
        return checkedAdd(checkedMultiply(seconds, BILLION), nanos);
    }

    public Duration plus(Duration amount) {
        if (amount == null) throw new NullPointerException("amount");
        return ofSeconds(checkedAdd(seconds, amount.seconds), (long) nanos + amount.nanos);
    }
    public Duration plusSeconds(long amount) {
        return ofSeconds(checkedAdd(seconds, amount), nanos);
    }
    public Duration plusMillis(long amount) {
        return ofSeconds(checkedAdd(seconds, amount / 1000L),
                         nanos + (amount % 1000L) * 1000000L);
    }
    public Duration plusNanos(long amount) {
        return ofSeconds(checkedAdd(seconds, amount / BILLION),
                         nanos + amount % BILLION);
    }
    public Duration plusMinutes(long amount) { return plusSeconds(checkedMultiply(amount, 60L)); }
    public Duration plusHours(long amount) { return plusSeconds(checkedMultiply(amount, 3600L)); }
    public Duration plusDays(long amount) { return plusSeconds(checkedMultiply(amount, 86400L)); }

    public Duration minus(Duration amount) {
        if (amount == null) throw new NullPointerException("amount");
        long secDiff;
        if (amount.seconds == Long.MIN_VALUE) {
            if (seconds > 0) throw new ArithmeticException("long overflow");
            if (seconds == 0) {
                // Borrow one second from the negative nanosecond difference.
                // This representable edge is missed by a naive checked sub.
                if (nanos >= amount.nanos) throw new ArithmeticException("long overflow");
                return new Duration(Long.MAX_VALUE, (int) (BILLION + nanos - amount.nanos));
            }
            secDiff = seconds - Long.MIN_VALUE;
        } else secDiff = checkedAdd(seconds, -amount.seconds);
        return ofSeconds(secDiff, (long) nanos - amount.nanos);
    }
    public Duration minusSeconds(long amount) {
        return amount == Long.MIN_VALUE ? plusSeconds(Long.MAX_VALUE).plusSeconds(1)
                                        : plusSeconds(-amount);
    }
    public Duration minusMillis(long amount) {
        return amount == Long.MIN_VALUE ? plusMillis(Long.MAX_VALUE).plusMillis(1)
                                        : plusMillis(-amount);
    }
    public Duration minusNanos(long amount) {
        return amount == Long.MIN_VALUE ? plusNanos(Long.MAX_VALUE).plusNanos(1)
                                        : plusNanos(-amount);
    }
    public Duration minusMinutes(long amount) {
        return amount == Long.MIN_VALUE ? plusMinutes(Long.MAX_VALUE).plusMinutes(1)
                                        : plusMinutes(-amount);
    }
    public Duration minusHours(long amount) {
        return amount == Long.MIN_VALUE ? plusHours(Long.MAX_VALUE).plusHours(1)
                                        : plusHours(-amount);
    }
    public Duration minusDays(long amount) {
        return amount == Long.MIN_VALUE ? plusDays(Long.MAX_VALUE).plusDays(1)
                                        : plusDays(-amount);
    }

    public Duration negated() {
        if (seconds == Long.MIN_VALUE) {
            if (nanos == 0) throw new ArithmeticException("long overflow");
            return ofSeconds(Long.MAX_VALUE, BILLION - nanos);
        }
        return ofSeconds(-seconds, -nanos);
    }
    public Duration abs() { return isNegative() ? negated() : this; }

    @Override
    public int compareTo(Duration other) {
        if (other == null) throw new NullPointerException("other");
        if (seconds != other.seconds) return seconds < other.seconds ? -1 : 1;
        return nanos == other.nanos ? 0 : nanos < other.nanos ? -1 : 1;
    }
    @Override
    public boolean equals(Object obj) {
        if (obj == this) return true;
        if (!(obj instanceof Duration)) return false;
        Duration other = (Duration) obj;
        return seconds == other.seconds && nanos == other.nanos;
    }
    @Override
    public int hashCode() { return (int) (seconds ^ (seconds >>> 32)) + 51 * nanos; }

    @Override
    public String toString() {
        if (isZero()) return "PT0S";
        // Java's text representation uses truncation toward zero for a
        // negative fractional duration, even when seconds are divisible by 60.
        boolean negativeFraction = seconds < 0 && nanos > 0;
        long wholeSeconds = negativeFraction ? seconds + 1 : seconds;
        int fraction = negativeFraction ? (int) (BILLION - nanos) : nanos;
        long hours = wholeSeconds / 3600L;
        int minutes = (int) ((wholeSeconds % 3600L) / 60L);
        int secs = (int) (wholeSeconds % 60L);
        StringBuilder out = new StringBuilder(32).append("PT");
        if (hours != 0) out.append(hours).append('H');
        if (minutes != 0) out.append(minutes).append('M');
        if (secs == 0 && fraction == 0 && out.length() > 2) return out.toString();
        if (negativeFraction && secs == 0) out.append("-0");
        else out.append(secs);
        if (fraction > 0) {
            String digits = String.valueOf(fraction + BILLION).substring(1);
            int width = 9;
            while (width > 1 && digits.charAt(width - 1) == '0') width--;
            out.append('.').append(digits.substring(0, width));
        }
        return out.append('S').toString();
    }
}
