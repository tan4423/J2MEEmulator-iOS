/* SPDX-License-Identifier: MIT */
package java.time;

import java.util.Calendar;

/**
 * Immutable ISO local date/time subset for miniJVM/CLDC (years 0001..9999).
 * A wall-clock value without a time zone, instant or daylight-saving rules.
 */
public final class LocalDateTime implements Comparable<LocalDateTime> {
    private static final long NANOS_PER_DAY = 86400000000000L;
    private final LocalDate date;
    private final LocalTime time;

    private LocalDateTime(LocalDate date, LocalTime time) {
        this.date = date;
        this.time = time;
    }

    public static LocalDateTime now() {
        Calendar clock = Calendar.getInstance();
        if (clock == null) throw new IllegalStateException("Calendar unavailable");
        return of(clock.get(Calendar.YEAR), clock.get(Calendar.MONTH) + 1,
                  clock.get(Calendar.DAY_OF_MONTH), clock.get(Calendar.HOUR_OF_DAY),
                  clock.get(Calendar.MINUTE), clock.get(Calendar.SECOND),
                  clock.get(Calendar.MILLISECOND) * 1000000);
    }

    public static LocalDateTime of(int year, int month, int day, int hour, int minute) {
        return of(year, month, day, hour, minute, 0, 0);
    }

    public static LocalDateTime of(int year, int month, int day, int hour, int minute,
                                   int second) {
        return of(year, month, day, hour, minute, second, 0);
    }

    public static LocalDateTime of(int year, int month, int day, int hour, int minute,
                                   int second, int nano) {
        return of(LocalDate.of(year, month, day), LocalTime.of(hour, minute, second, nano));
    }

    public static LocalDateTime of(LocalDate date, LocalTime time) {
        if (date == null) throw new NullPointerException("date");
        if (time == null) throw new NullPointerException("time");
        return new LocalDateTime(date, time);
    }

    /** ISO yyyy-MM-dd'T'HH:mm[:ss[.fraction]] (year range 0001..9999). */
    public static LocalDateTime parse(CharSequence text) {
        if (text == null) throw new NullPointerException("text");
        String value = text.toString();
        int at = value.indexOf('T');
        if (at != 10) throw new IllegalArgumentException("Expected ISO local date time");
        LocalDate date = LocalDate.parse(value.substring(0, at));
        String timePart = value.substring(at + 1);
        if (timePart.length() < 5 || timePart.charAt(2) != ':') {
            throw new IllegalArgumentException("Expected HH:mm");
        }
        int hour = number(timePart, 0, 2);
        int minute = number(timePart, 3, 5);
        int second = 0;
        int nano = 0;
        if (timePart.length() > 5) {
            if (timePart.length() < 8 || timePart.charAt(5) != ':') {
                throw new IllegalArgumentException("Expected seconds");
            }
            second = number(timePart, 6, 8);
            if (timePart.length() > 8) {
                if (timePart.charAt(8) != '.' || timePart.length() > 18) {
                    throw new IllegalArgumentException("Invalid fraction");
                }
                int digits = timePart.length() - 9;
                if (digits < 1 || digits > 9) throw new IllegalArgumentException("Invalid fraction");
                nano = number(timePart, 9, timePart.length());
                for (int i = digits; i < 9; i++) nano *= 10;
            }
        }
        return of(date, LocalTime.of(hour, minute, second, nano));
    }

    private static int number(CharSequence value, int begin, int end) {
        int result = 0;
        for (int i = begin; i < end; i++) {
            char c = value.charAt(i);
            if (c < '0' || c > '9') throw new IllegalArgumentException("Invalid ISO number");
            result = result * 10 + c - '0';
        }
        return result;
    }

    public LocalDate toLocalDate() { return date; }
    public LocalTime toLocalTime() { return time; }
    public int getYear() { return date.getYear(); }
    public int getMonthValue() { return date.getMonthValue(); }
    public int getDayOfMonth() { return date.getDayOfMonth(); }
    public int getDayOfYear() { return date.getDayOfYear(); }
    public int getHour() { return time.getHour(); }
    public int getMinute() { return time.getMinute(); }
    public int getSecond() { return time.getSecond(); }
    public int getNano() { return time.getNano(); }

    public LocalDateTime withYear(int value) { return of(date.withYear(value), time); }
    public LocalDateTime withMonth(int value) { return of(date.withMonth(value), time); }
    public LocalDateTime withDayOfMonth(int value) { return of(date.withDayOfMonth(value), time); }
    public LocalDateTime withDayOfYear(int value) { return of(date.withDayOfYear(value), time); }
    public LocalDateTime withHour(int value) {
        return of(date, LocalTime.of(value, getMinute(), getSecond(), getNano()));
    }
    public LocalDateTime withMinute(int value) {
        return of(date, LocalTime.of(getHour(), value, getSecond(), getNano()));
    }
    public LocalDateTime withSecond(int value) { return of(date, time.withSecond(value)); }
    public LocalDateTime withNano(int value) { return of(date, time.withNano(value)); }

    public LocalDateTime plusDays(long amount) { return of(date.plusDays(amount), time); }
    public LocalDateTime minusDays(long amount) { return of(date.minusDays(amount), time); }
    public LocalDateTime plusWeeks(long amount) { return of(date.plusWeeks(amount), time); }
    public LocalDateTime minusWeeks(long amount) { return of(date.minusWeeks(amount), time); }
    public LocalDateTime plusMonths(long amount) { return of(date.plusMonths(amount), time); }
    public LocalDateTime minusMonths(long amount) { return of(date.minusMonths(amount), time); }
    public LocalDateTime plusYears(long amount) { return of(date.plusYears(amount), time); }
    public LocalDateTime minusYears(long amount) { return of(date.minusYears(amount), time); }

    private long nanoOfDay() {
        return (((getHour() * 60L + getMinute()) * 60L + getSecond()) *
                1000000000L) + getNano();
    }

    /** Divide first, then add the sub-day part, to avoid long overflow. */
    public LocalDateTime plusNanos(long amount) {
        long dateShift = amount / NANOS_PER_DAY;
        long part = amount % NANOS_PER_DAY;
        long value = nanoOfDay() + part;
        if (value < 0) { value += NANOS_PER_DAY; dateShift--; }
        else if (value >= NANOS_PER_DAY) { value -= NANOS_PER_DAY; dateShift++; }
        LocalDate newDate = date.plusDays(dateShift);
        int hour = (int) (value / 3600000000000L);
        value %= 3600000000000L;
        int minute = (int) (value / 60000000000L);
        value %= 60000000000L;
        int second = (int) (value / 1000000000L);
        int nano = (int) (value % 1000000000L);
        return of(newDate, LocalTime.of(hour, minute, second, nano));
    }

    public LocalDateTime minusNanos(long amount) {
        if (amount == Long.MIN_VALUE) return plusNanos(Long.MAX_VALUE).plusNanos(1);
        return plusNanos(-amount);
    }

    public LocalDateTime plusSeconds(long amount) {
        long days = amount / 86400L;
        long part = amount % 86400L;
        return plusDays(days).plusNanos(part * 1000000000L);
    }
    public LocalDateTime minusSeconds(long amount) {
        if (amount == Long.MIN_VALUE) return plusSeconds(Long.MAX_VALUE).plusSeconds(1);
        return plusSeconds(-amount);
    }

    public LocalDateTime plusMinutes(long amount) {
        long days = amount / 1440L;
        long part = amount % 1440L;
        return plusDays(days).plusNanos(part * 60000000000L);
    }
    public LocalDateTime minusMinutes(long amount) {
        if (amount == Long.MIN_VALUE) return plusMinutes(Long.MAX_VALUE).plusMinutes(1);
        return plusMinutes(-amount);
    }

    public LocalDateTime plusHours(long amount) {
        long days = amount / 24L;
        long part = amount % 24L;
        return plusDays(days).plusNanos(part * 3600000000000L);
    }
    public LocalDateTime minusHours(long amount) {
        if (amount == Long.MIN_VALUE) return plusHours(Long.MAX_VALUE).plusHours(1);
        return plusHours(-amount);
    }

    public boolean isBefore(LocalDateTime other) { return compareTo(other) < 0; }
    public boolean isAfter(LocalDateTime other) { return compareTo(other) > 0; }
    public boolean isEqual(LocalDateTime other) { return compareTo(other) == 0; }

    @Override
    public int compareTo(LocalDateTime other) {
        if (other == null) throw new NullPointerException("other");
        int dayOrder = date.compareTo(other.date);
        return dayOrder != 0 ? dayOrder : time.compareTo(other.time);
    }

    @Override
    public boolean equals(Object other) {
        if (other == this) return true;
        if (!(other instanceof LocalDateTime)) return false;
        LocalDateTime value = (LocalDateTime) other;
        return date.equals(value.date) && time.equals(value.time);
    }

    @Override
    public int hashCode() { return date.hashCode() ^ time.hashCode(); }

    @Override
    public String toString() { return date.toString() + 'T' + time.toString(); }
}
