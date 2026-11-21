"""Host-JDK regression for JarBox's immutable Java 8 LocalDate/LocalDateTime subset.

The java.time source is compiled as Java 8 for the boot JAR separately.
For executing tests on a host JVM, temporarily rename its package so the
installed JDK's java.base classes cannot silently mask the implementation.
"""
import re
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SRC = ROOT / "J2MEEmulator" / "RuntimePatches" / "java" / "time"

TEST_JAVA = r"""
import java.util.Random;
import java.time.*;

public class TestDates {
    static void eq(String actual, String expected, String context) {
        if (!actual.equals(expected)) {
            throw new AssertionError(context+" expected="+expected+" actual="+actual);
        }
    }
    static void check(boolean okay, String context) {
        if (!okay) throw new AssertionError(context);
    }
    static void dateCheck(int y, int m, int d) {
        java.time.LocalDate a = java.time.LocalDate.of(y,m,d);
        jarbox.compat.time.LocalDate b = jarbox.compat.time.LocalDate.of(y,m,d);
        eq(b.toString(),a.toString(),"date toString");
        eq(jarbox.compat.time.LocalDate.parse(a.toString()).toString(),a.toString(),"date parse");
        eq(jarbox.compat.time.LocalDate.ofYearDay(y,a.getDayOfYear()).toString(),
           a.toString(),"date ofYearDay");
        eq(jarbox.compat.time.LocalDate.ofEpochDay(a.toEpochDay()).toString(),
           a.toString(),"date ofEpochDay");
        check(b.toEpochDay() == a.toEpochDay(),"epoch day");
        check(b.isLeapYear() == a.isLeapYear(),"leap");
        check(b.getDayOfYear() == a.getDayOfYear(),"day-of-year");
        check(b.hashCode() == a.hashCode(),"date hash");
        check(b.lengthOfMonth() == a.lengthOfMonth(),"month length");
        check(b.lengthOfYear() == a.lengthOfYear(),"year length");
        if (y > 3 && y < 9996) {
            for (long n : new long[] {-400,-30,-1,0,1,30,400}) {
                eq(b.plusDays(n).toString(),a.plusDays(n).toString(),"plusDays");
                eq(b.minusDays(n).toString(),a.minusDays(n).toString(),"minusDays");
            }
            for (long n : new long[] {-24,-1,0,1,24}) {
                eq(b.plusMonths(n).toString(),a.plusMonths(n).toString(),"plusMonths");
                eq(b.minusMonths(n).toString(),a.minusMonths(n).toString(),"minusMonths");
            }
            eq(b.plusYears(2).toString(),a.plusYears(2).toString(),"plusYears");
            eq(b.minusYears(2).toString(),a.minusYears(2).toString(),"minusYears");
        }
    }
    static void dateTimeCheck(int y, int m, int d, int h, int mi, int s, int n) {
        java.time.LocalDateTime a = java.time.LocalDateTime.of(y,m,d,h,mi,s,n);
        jarbox.compat.time.LocalDateTime b =
            jarbox.compat.time.LocalDateTime.of(y,m,d,h,mi,s,n);
        eq(b.toString(),a.toString(),"dateTime toString");
        eq(jarbox.compat.time.LocalDateTime.parse(a.toString()).toString(),
           a.toString(),"dateTime parse");
        check(b.toLocalDate().toEpochDay() == a.toLocalDate().toEpochDay(),"date part");
        check(b.toLocalTime().equals(a.toLocalTime()),"time part");
        check(b.hashCode() == a.hashCode(),"dateTime hash");
        if (y > 25 && y < 9975) {
            for (long amount : new long[] {-86400,-1,0,1,86400}) {
                eq(b.plusSeconds(amount).toString(),
                   a.plusSeconds(amount).toString(),"plusSeconds");
                eq(b.minusSeconds(amount).toString(),
                   a.minusSeconds(amount).toString(),"minusSeconds");
                eq(b.plusMinutes(amount).toString(),
                   a.plusMinutes(amount).toString(),"plusMinutes");
                eq(b.plusHours(amount).toString(),
                   a.plusHours(amount).toString(),"plusHours");
                eq(b.plusNanos(amount).toString(),
                   a.plusNanos(amount).toString(),"plusNanos");
                eq(b.minusNanos(amount).toString(),
                   a.minusNanos(amount).toString(),"minusNanos");
            }
        }
    }
    static void invalid(Runnable action) {
        try {
            action.run();
            throw new AssertionError("Expected rejection");
        } catch (RuntimeException expected) { }
    }
    public static void main(String[] args) {
        dateCheck(1,1,1);
        dateCheck(9999,12,31);
        dateCheck(2000,2,29);
        dateCheck(1900,2,28);
        dateTimeCheck(2000,2,29,23,59,59,999999999);
        dateTimeCheck(2000,2,29,0,0,0,0);
        Random random = new Random(100201);
        for (int i=0; i<3000; i++) {
            int year=1+random.nextInt(9999);
            int month=1+random.nextInt(12);
            int day=1+random.nextInt(
                java.time.LocalDate.of(year,month,1).lengthOfMonth());
            dateCheck(year,month,day);
            dateTimeCheck(year,month,day,random.nextInt(24),
                          random.nextInt(60),random.nextInt(60),
                          random.nextInt(1000000000));
        }
        invalid(() -> jarbox.compat.time.LocalDate.of(1900,2,29));
        invalid(() -> jarbox.compat.time.LocalDate.of(2000,13,1));
        invalid(() -> jarbox.compat.time.LocalDate.parse("2026/11/21"));
        invalid(() -> jarbox.compat.time.LocalDate.ofEpochDay(-719163));
        invalid(() -> jarbox.compat.time.LocalDate.ofEpochDay(2932897));
        invalid(() -> jarbox.compat.time.LocalDateTime.parse("2026-11-21T24:00"));
        invalid(() -> jarbox.compat.time.LocalDateTime.parse("2026-11-21T10:60"));
        System.out.println("Java8 date compatibility vectors passed");
    }
}
"""


class Java8BootDatesTest(unittest.TestCase):
    def test_local_dates_against_host_reference(self):
        if not shutil.which("javac") or not shutil.which("java"):
            self.skipTest("JDK unavailable")
        with tempfile.TemporaryDirectory(prefix="jarbox-java8-dates-") as temp:
            root = Path(temp)
            source_dir = root / "jarbox" / "compat" / "time"
            source_dir.mkdir(parents=True)
            files = []
            for name in ("LocalDate", "LocalDateTime"):
                source = (SRC / (name + ".java")).read_text(encoding="utf-8")
                source = source.replace(
                    "package java.time;", "package jarbox.compat.time;", 1)
                if name == "LocalDateTime":
                    # Use the host LocalTime, whose method signatures are
                    # already supported by the existing JarBox boot patch.
                    source = re.sub(r"(?<![\w.])LocalTime\b",
                                    "java.time.LocalTime", source)
                filename = source_dir / (name + ".java")
                filename.write_text(source, encoding="utf-8")
                files.append(str(filename))
            java_test = root / "TestDates.java"
            java_test.write_text(TEST_JAVA, encoding="utf-8")
            classes = root / "classes"
            subprocess.run(["javac", "--release", "8", "-d", str(classes)]
                           + files + [str(java_test)],
                           check=True, capture_output=True, text=True)
            subprocess.run(["java", "-cp", str(classes), "TestDates"],
                           check=True, capture_output=True, text=True)


if __name__ == "__main__":
    unittest.main()
