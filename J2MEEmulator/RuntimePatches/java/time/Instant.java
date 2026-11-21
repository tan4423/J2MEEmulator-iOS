/* SPDX-License-Identifier: MIT */
package java.time;

/**
 * Immutable UTC instant for miniJVM's Java 8 compatibility boot layer.
 * Supports ISO calendar years 0001 through 9999; it is not the full JDK API.
 */
public final class Instant implements Comparable<Instant> {
    private static final long BILLION = 1000000000L;
    private static final long MIN_SECOND = -62135596800L;
    private static final long MAX_SECOND = 253402300799L;
    public static final Instant EPOCH = new Instant(0, 0);
    private final long seconds;
    private final int nanos;

    private Instant(long seconds, int nanos) {
        this.seconds = seconds;
        this.nanos = nanos;
    }

    private static long checkedAdd(long a, long b) {
        long result = a + b;
        if (((a ^ result) & (b ^ result)) < 0) {
            throw new ArithmeticException("long overflow");
        }
        return result;
    }

    private static void checkSeconds(long value) {
        if (value < MIN_SECOND || value > MAX_SECOND)
            throw new IllegalArgumentException("Instant outside years 0001..9999");
    }

    public static Instant now() { return ofEpochMilli(System.currentTimeMillis()); }

    public static Instant ofEpochSecond(long epochSecond) {
        checkSeconds(epochSecond);
        return epochSecond == 0 ? EPOCH : new Instant(epochSecond, 0);
    }

    public static Instant ofEpochSecond(long epochSecond, long nanoAdjustment) {
        long sec = checkedAdd(epochSecond, nanoAdjustment / BILLION);
        long nano = nanoAdjustment % BILLION;
        if (nano < 0) {
            sec = checkedAdd(sec, -1);
            nano += BILLION;
        }
        checkSeconds(sec);
        return sec == 0 && nano == 0 ? EPOCH : new Instant(sec, (int) nano);
    }

    public static Instant ofEpochMilli(long epochMilli) {
        return ofEpochSecond(epochMilli / 1000L, (epochMilli % 1000L) * 1000000L);
    }

    public long getEpochSecond() { return seconds; }
    public int getNano() { return nanos; }

    public long toEpochMilli() {
        // Supported range guarantees multiplying seconds by 1000 is safe.
        return seconds * 1000L + nanos / 1000000;
    }

    public Instant plusSeconds(long amount) {
        return ofEpochSecond(checkedAdd(seconds, amount), nanos);
    }
    public Instant plusMillis(long amount) {
        return ofEpochSecond(checkedAdd(seconds, amount / 1000L),
                             nanos + (amount % 1000L) * 1000000L);
    }
    public Instant plusNanos(long amount) {
        return ofEpochSecond(checkedAdd(seconds, amount / BILLION),
                             nanos + amount % BILLION);
    }
    public Instant minusSeconds(long amount) {
        return amount == Long.MIN_VALUE ? plusSeconds(Long.MAX_VALUE).plusSeconds(1)
                                        : plusSeconds(-amount);
    }
    public Instant minusMillis(long amount) {
        return amount == Long.MIN_VALUE ? plusMillis(Long.MAX_VALUE).plusMillis(1)
                                        : plusMillis(-amount);
    }
    public Instant minusNanos(long amount) {
        return amount == Long.MIN_VALUE ? plusNanos(Long.MAX_VALUE).plusNanos(1)
                                        : plusNanos(-amount);
    }
    public boolean isBefore(Instant other) { return compareTo(other) < 0; }
    public boolean isAfter(Instant other) { return compareTo(other) > 0; }

    @Override
    public int compareTo(Instant other) {
        if (other == null) throw new NullPointerException("other");
        if (seconds != other.seconds) return seconds < other.seconds ? -1 : 1;
        return nanos == other.nanos ? 0 : nanos < other.nanos ? -1 : 1;
    }
    @Override
    public boolean equals(Object obj) {
        if (obj == this) return true;
        if (!(obj instanceof Instant)) return false;
        Instant other = (Instant) obj;
        return seconds == other.seconds && nanos == other.nanos;
    }
    @Override
    public int hashCode() {
        return (int) (seconds ^ (seconds >>> 32)) + 51 * nanos;
    }

    private static int number(String str, int begin, int end) {
        int value = 0;
        for (int i = begin; i < end; ++i) {
            char c = str.charAt(i);
            if (c < '0' || c > '9') throw new IllegalArgumentException("Invalid UTC instant");
            value = value * 10 + c - '0';
        }
        return value;
    }

    /** A strict UTC 'Z' subset of ISO-8601, without offset-zone parsing. */
    public static Instant parse(CharSequence text) {
        if (text == null) throw new NullPointerException("text");
        String str = text.toString();
        int len = str.length();
        if (len < 20 || len > 30 || str.charAt(10) != 'T' ||
            str.charAt(13) != ':' || str.charAt(16) != ':' ||
            str.charAt(len - 1) != 'Z')
            throw new IllegalArgumentException("Expected UTC yyyy-MM-ddTHH:mm:ssZ");
        LocalDate date = LocalDate.parse(str.substring(0, 10));
        int hour = number(str, 11, 13);
        int minute = number(str, 14, 16);
        int second = number(str, 17, 19);
        int nano = 0;
        if (len != 20) {
            if (str.charAt(19) != '.' || len < 22 || len > 30)
                throw new IllegalArgumentException("Invalid fractional seconds");
            int digits = len - 21;
            if (digits > 9) throw new IllegalArgumentException("Invalid fraction precision");
            nano = number(str, 20, len - 1);
            for (int i = digits; i < 9; i++) nano *= 10;
        }
        LocalTime.of(hour, minute, second, nano); // Validate each time component.
        long secs = date.toEpochDay() * 86400L + hour * 3600L + minute * 60L + second;
        return ofEpochSecond(secs, nano);
    }

    private static void append(StringBuilder sb, int value, int width) {
        String num = String.valueOf(value);
        for (int i = num.length(); i < width; ++i) sb.append('0');
        sb.append(num);
    }

    @Override
    public String toString() {
        long epochDay = seconds / 86400L;
        long secsOfDay = seconds % 86400L;
        if (secsOfDay < 0) { epochDay--; secsOfDay += 86400L; }
        int hour = (int) (secsOfDay / 3600L);
        int minute = (int) ((secsOfDay % 3600L) / 60L);
        int second = (int) (secsOfDay % 60L);
        StringBuilder sb = new StringBuilder(32);
        sb.append(LocalDate.ofEpochDay(epochDay)).append('T');
        append(sb, hour, 2); sb.append(':');
        append(sb, minute, 2); sb.append(':');
        append(sb, second, 2);
        if (nanos != 0) {
            sb.append('.');
            int width = nanos % 1000000 == 0 ? 3 : nanos % 1000 == 0 ? 6 : 9;
            String digits = String.valueOf(nanos + BILLION).substring(1);
            sb.append(digits.substring(0, width));
        }
        return sb.append('Z').toString();
    }
}
