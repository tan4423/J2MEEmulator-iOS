/* SPDX-License-Identifier: MIT */
package java.time;

import java.util.Calendar;

/**
 * Immutable ISO proleptic-Gregorian date for the JarBox CLDC boot runtime.
 * Deliberate subset of java.time.LocalDate: years 0001..9999 only.
 * No zone conversion, temporal framework, or game-specific behavior.
 */
public final class LocalDate implements Comparable<LocalDate> {
    private final int year;
    private final int month;
    private final int day;

    private LocalDate(int year, int month, int day) {
        this.year = year;
        this.month = month;
        this.day = day;
    }

    public static LocalDate now() {
        Calendar clock = Calendar.getInstance();
        if (clock == null) throw new IllegalStateException("Calendar unavailable");
        return of(clock.get(Calendar.YEAR), clock.get(Calendar.MONTH) + 1,
                  clock.get(Calendar.DAY_OF_MONTH));
    }

    public static LocalDate of(int year, int month, int dayOfMonth) {
        if (year < 1 || year > 9999 || month < 1 || month > 12 ||
            dayOfMonth < 1 || dayOfMonth > daysInMonth(year, month)) {
            throw new IllegalArgumentException("Invalid ISO date");
        }
        return new LocalDate(year, month, dayOfMonth);
    }

    public static LocalDate ofYearDay(int year, int dayOfYear) {
        if (year < 1 || year > 9999 || dayOfYear < 1 ||
            dayOfYear > (isLeap(year) ? 366 : 365)) {
            throw new IllegalArgumentException("Invalid ISO ordinal date");
        }
        int month = 1;
        while (dayOfYear > daysInMonth(year, month)) {
            dayOfYear -= daysInMonth(year, month++);
        }
        return new LocalDate(year, month, dayOfYear);
    }

    public static LocalDate parse(CharSequence text) {
        if (text == null) throw new NullPointerException("text");
        if (text.length() != 10 || text.charAt(4) != '-' || text.charAt(7) != '-') {
            throw new IllegalArgumentException("Expected yyyy-MM-dd");
        }
        int year = number(text, 0, 4);
        int month = number(text, 5, 7);
        int day = number(text, 8, 10);
        return of(year, month, day);
    }

    private static int number(CharSequence text, int start, int end) {
        int value = 0;
        for (int i = start; i < end; i++) {
            char c = text.charAt(i);
            if (c < '0' || c > '9') throw new IllegalArgumentException("Invalid ISO date");
            value = value * 10 + c - '0';
        }
        return value;
    }

    private static boolean isLeap(int year) {
        return (year % 4 == 0) && (year % 100 != 0 || year % 400 == 0);
    }

    public boolean isLeapYear() { return isLeap(year); }

    private static int daysInMonth(int year, int month) {
        switch (month) {
            case 2: return isLeap(year) ? 29 : 28;
            case 4: case 6: case 9: case 11: return 30;
            default: return 31;
        }
    }

    public int getYear() { return year; }
    public int getMonthValue() { return month; }
    public int getDayOfMonth() { return day; }
    public int lengthOfMonth() { return daysInMonth(year, month); }
    public int lengthOfYear() { return isLeapYear() ? 366 : 365; }

    public int getDayOfYear() {
        int result = day;
        for (int m = 1; m < month; m++) result += daysInMonth(year, m);
        return result;
    }

    private static long daysBeforeYear(int year) {
        long y = year - 1L;
        return y * 365 + y / 4 - y / 100 + y / 400;
    }

    /** Days since 1970-01-01; valid for the supported ISO year range. */
    public long toEpochDay() {
        return daysBeforeYear(year) + getDayOfYear() - 1L - 719162L;
    }

    public static LocalDate ofEpochDay(long epochDay) {
        long ordinal = epochDay + 719162L;
        if (epochDay < -719162L || epochDay > 2932896L) {
            throw new IllegalArgumentException("Date outside 0001..9999");
        }
        int lo = 1, hi = 9999;
        while (lo <= hi) {
            int middle = (lo + hi) >>> 1;
            long first = daysBeforeYear(middle);
            long next = daysBeforeYear(middle + 1);
            if (ordinal < first) hi = middle - 1;
            else if (ordinal >= next) lo = middle + 1;
            else return ofYearDay(middle, (int) (ordinal - first + 1));
        }
        throw new IllegalArgumentException("Invalid epoch day");
    }

    public LocalDate plusDays(long days) {
        long now = toEpochDay();
        if (days < -719162L - now || days > 2932896L - now) {
            throw new IllegalArgumentException("Date outside 0001..9999");
        }
        return days == 0 ? this : ofEpochDay(now + days);
    }

    public LocalDate minusDays(long days) {
        if (days == Long.MIN_VALUE) throw new IllegalArgumentException("Date overflow");
        return plusDays(-days);
    }

    public LocalDate plusWeeks(long weeks) {
        if (weeks < -600000L || weeks > 600000L) {
            throw new IllegalArgumentException("Date outside 0001..9999");
        }
        return plusDays(weeks * 7);
    }

    public LocalDate minusWeeks(long weeks) {
        if (weeks == Long.MIN_VALUE) throw new IllegalArgumentException("Date overflow");
        return plusWeeks(-weeks);
    }

    public LocalDate plusMonths(long months) {
        long serial = (year - 1L) * 12 + month - 1 + months;
        if (months < -119988L || months > 119988L || serial < 0 || serial >= 9999L * 12) {
            throw new IllegalArgumentException("Date outside 0001..9999");
        }
        int nextYear = (int) (serial / 12 + 1);
        int nextMonth = (int) (serial % 12 + 1);
        return of(nextYear, nextMonth, Math.min(day, daysInMonth(nextYear, nextMonth)));
    }

    public LocalDate minusMonths(long months) {
        if (months == Long.MIN_VALUE) throw new IllegalArgumentException("Date overflow");
        return plusMonths(-months);
    }

    public LocalDate plusYears(long years) {
        long nextYear = year + years;
        if (years < -9999L || years > 9999L || nextYear < 1 || nextYear > 9999) {
            throw new IllegalArgumentException("Date outside 0001..9999");
        }
        int y = (int) nextYear;
        return of(y, month, Math.min(day, daysInMonth(y, month)));
    }

    public LocalDate minusYears(long years) {
        if (years == Long.MIN_VALUE) throw new IllegalArgumentException("Date overflow");
        return plusYears(-years);
    }

    public LocalDate withYear(int value) { return plusYears((long) value - year); }
    public LocalDate withMonth(int value) { return plusMonths((long) value - month); }
    public LocalDate withDayOfMonth(int value) { return of(year, month, value); }
    public LocalDate withDayOfYear(int value) { return ofYearDay(year, value); }

    public boolean isBefore(LocalDate other) { return compareTo(other) < 0; }
    public boolean isAfter(LocalDate other) { return compareTo(other) > 0; }
    public boolean isEqual(LocalDate other) { return compareTo(other) == 0; }

    @Override
    public int compareTo(LocalDate other) {
        if (other == null) throw new NullPointerException("other");
        if (year != other.year) return year < other.year ? -1 : 1;
        if (month != other.month) return month < other.month ? -1 : 1;
        return day == other.day ? 0 : day < other.day ? -1 : 1;
    }

    @Override
    public boolean equals(Object other) {
        if (this == other) return true;
        if (!(other instanceof LocalDate)) return false;
        LocalDate value = (LocalDate) other;
        return year == value.year && month == value.month && day == value.day;
    }

    @Override
    public int hashCode() {
        return (year & 0xFFFFF800) ^ ((year << 11) + (month << 6) + day);
    }

    private static void pad(StringBuilder text, int number, int digits) {
        String part = String.valueOf(number);
        for (int i = part.length(); i < digits; i++) text.append('0');
        text.append(part);
    }

    @Override
    public String toString() {
        StringBuilder result = new StringBuilder(10);
        pad(result, year, 4);
        result.append('-');
        pad(result, month, 2);
        result.append('-');
        pad(result, day, 2);
        return result.toString();
    }
}
