/*
 * Java 8 LocalTime compatibility for the miniJVM/CLDC boot runtime.
 *
 * The JVM bundled with JarBox lacks java.time, but MicroEmulator mods
 * may use these time-of-day APIs. This immutable value type provides the
 * Java 8 method descriptors exercised by the unmodified TrungDucTV JAR.
 * It uses Calendar's local time zone (never a hard-coded hour offset).
 * No server protocol, game bytecode, or virtual clock is altered.
 *
 * This is a focused subset, NOT a complete java.time implementation.
 */
package java.time;

import java.util.Calendar;

public final class LocalTime implements Comparable<LocalTime> {
    private final int hour;
    private final int minute;
    private final int second;
    private final int nano;

    private LocalTime(int hour, int minute, int second, int nano) {
        this.hour = hour;
        this.minute = minute;
        this.second = second;
        this.nano = nano;
    }

    public static LocalTime now() {
        Calendar clock = Calendar.getInstance();
        if (clock == null) {
            throw new IllegalStateException("Calendar implementation unavailable");
        }
        return of(clock.get(Calendar.HOUR_OF_DAY),
                  clock.get(Calendar.MINUTE),
                  clock.get(Calendar.SECOND),
                  clock.get(Calendar.MILLISECOND) * 1000000);
    }

    public static LocalTime of(int hour, int minute) {
        return of(hour, minute, 0, 0);
    }

    public static LocalTime of(int hour, int minute, int second) {
        return of(hour, minute, second, 0);
    }

    public static LocalTime of(int hour, int minute, int second, int nanoOfSecond) {
        checkRange(hour, 0, 23, "hour");
        checkRange(minute, 0, 59, "minute");
        checkRange(second, 0, 59, "second");
        checkRange(nanoOfSecond, 0, 999999999, "nano");
        return new LocalTime(hour, minute, second, nanoOfSecond);
    }

    private static void checkRange(int v, int lo, int hi, String name) {
        if (v < lo || v > hi) {
            throw new IllegalArgumentException("Invalid " + name + ": " + v);
        }
    }

    public LocalTime withSecond(int value) {
        checkRange(value, 0, 59, "second");
        return value == second ? this : new LocalTime(hour, minute, value, nano);
    }

    public LocalTime withNano(int value) {
        checkRange(value, 0, 999999999, "nano");
        return value == nano ? this : new LocalTime(hour, minute, second, value);
    }

    public int getHour()   { return hour; }
    public int getMinute() { return minute; }
    public int getSecond() { return second; }
    public int getNano()   { return nano; }

    @Override
    public boolean equals(Object object) {
        if (object == this) return true;
        if (!(object instanceof LocalTime)) return false;
        LocalTime other = (LocalTime) object;
        return hour == other.hour && minute == other.minute &&
               second == other.second && nano == other.nano;
    }

    @Override
    public int hashCode() {
        long nanoOfDay = ((hour * 60L + minute) * 60L + second) *
                          1000000000L + nano;
        return (int) (nanoOfDay ^ (nanoOfDay >>> 32));
    }

    @Override
    public int compareTo(LocalTime other) {
        if (other == null) throw new NullPointerException("other");
        if (hour != other.hour) return hour < other.hour ? -1 : 1;
        if (minute != other.minute) return minute < other.minute ? -1 : 1;
        if (second != other.second) return second < other.second ? -1 : 1;
        if (nano != other.nano) return nano < other.nano ? -1 : 1;
        return 0;
    }

    private static void appendTwo(StringBuilder result, int value) {
        if (value < 10) result.append('0');
        result.append(value);
    }

    @Override
    public String toString() {
        StringBuilder result = new StringBuilder(18);
        appendTwo(result, hour);
        result.append(':');
        appendTwo(result, minute);
        if (second != 0 || nano != 0) {
            result.append(':');
            appendTwo(result, second);
            if (nano != 0) {
                result.append('.');
                String digits = String.valueOf(nano + 1000000000).substring(1);
                int width = (nano % 1000000 == 0) ? 3 :
                            (nano % 1000 == 0) ? 6 : 9;
                result.append(digits.substring(0, width));
            }
        }
        return result.toString();
    }
}
