"""Compare Java 8 boot Instant/Duration subset to the host JDK.

The original java.time sources are compiled by the IPA workflow into the boot
JAR; package renaming here only lets the host JDK execute the same algorithms
without masking them with its own java.base implementations.
"""
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
TIME_SRC = ROOT / "J2MEEmulator" / "RuntimePatches" / "java" / "time"

FIXTURE = r"""
import java.time.Duration;
import java.time.Instant;
import java.util.Random;

public class TestJava8InstantDuration {
    static void eq(Object got, Object expected, String name) {
        if (!got.equals(expected))
            throw new AssertionError(name + ": " + got + " != " + expected);
    }
    static void checkInstant(long seconds, int nanos) {
        Instant expected = Instant.ofEpochSecond(seconds, nanos);
        jarbox.compat.time.Instant got =
            jarbox.compat.time.Instant.ofEpochSecond(seconds, nanos);
        eq(got.toString(), expected.toString(), "Instant ISO");
        eq(got.getEpochSecond(), expected.getEpochSecond(), "Instant seconds");
        eq(got.getNano(), expected.getNano(), "Instant nanos");
        eq(got.hashCode(), expected.hashCode(), "Instant hash");
        eq(got.toEpochMilli(), expected.toEpochMilli(), "Instant millis");
        eq(jarbox.compat.time.Instant.parse(expected.toString()).toString(),
           expected.toString(), "Instant.parse roundtrip");
        if (seconds > -62135500000L && seconds < 253402200000L) {
            eq(got.plusNanos(133141L).toString(),
               expected.plusNanos(133141L).toString(), "Instant plusNanos");
            eq(got.plusMillis(-100001L).toString(),
               expected.plusMillis(-100001L).toString(), "Instant plusMillis");
            eq(got.minusSeconds(-2L).toString(),
               expected.minusSeconds(-2L).toString(), "Instant minusSeconds");
        }
    }
    static void checkDuration(long seconds, long nanos) {
        Duration expected = Duration.ofSeconds(seconds, nanos);
        jarbox.compat.time.Duration got =
            jarbox.compat.time.Duration.ofSeconds(seconds, nanos);
        eq(got.toString(), expected.toString(), "Duration ISO");
        eq(got.getSeconds(), expected.getSeconds(), "Duration seconds");
        eq(got.getNano(), expected.getNano(), "Duration nanos");
        eq(got.hashCode(), expected.hashCode(), "Duration hash");
        eq(got.toDays(), expected.toDays(), "Duration days");
        eq(got.toHours(), expected.toHours(), "Duration hours");
        eq(got.toMinutes(), expected.toMinutes(), "Duration minutes");
        eq(got.plusNanos(100000001L).toString(),
           expected.plusNanos(100000001L).toString(), "Duration plusNanos");
        eq(got.plusSeconds(2L).toString(),
           expected.plusSeconds(2L).toString(), "Duration plusSeconds");
        eq(got.minusMillis(500L).toString(),
           expected.minusMillis(500L).toString(), "Duration minusMillis");
        eq(got.negated().toString(), expected.negated().toString(),
           "Duration negated");
        eq(got.abs().toString(), expected.abs().toString(), "Duration abs");
        if (seconds > -100000000L && seconds < 100000000L) {
            eq(got.toMillis(), expected.toMillis(), "Duration toMillis");
            eq(got.toNanos(), expected.toNanos(), "Duration toNanos");
        }
    }
    static void checkDurationEdges() {
        long[] seconds = {Long.MIN_VALUE, Long.MIN_VALUE+1, -5, -1,
                          0, 1, 5, Long.MAX_VALUE-1, Long.MAX_VALUE};
        int[] ns = {0, 1, 999999999};
        for (long a : seconds) for (long b : seconds)
            for (int nano : ns) {
                Duration left = Duration.ofSeconds(a, nano);
                Duration right = Duration.ofSeconds(b, nano);
                jarbox.compat.time.Duration x =
                    jarbox.compat.time.Duration.ofSeconds(a, nano);
                jarbox.compat.time.Duration y =
                    jarbox.compat.time.Duration.ofSeconds(b, nano);
                try {
                    Duration result = left.minus(right);
                    jarbox.compat.time.Duration got = x.minus(y);
                    eq(got.getSeconds(), result.getSeconds(), "edge seconds");
                    eq(got.getNano(), result.getNano(), "edge nanos");
                } catch (ArithmeticException overflow) {
                    try { x.minus(y); throw new AssertionError("Expected overflow"); }
                    catch (ArithmeticException correct) { }
                }
            }
        eq(jarbox.compat.time.Duration.ofSeconds(0, 0).minus(
           jarbox.compat.time.Duration.ofSeconds(Long.MIN_VALUE, 1)).toString(),
           Duration.ofSeconds(0, 0).minus(
           Duration.ofSeconds(Long.MIN_VALUE, 1)).toString(),
           "Long.MIN_VALUE fractional subtraction");
    }
    public static void main(String[] args) {
        checkInstant(0, 0);
        checkInstant(-62135596800L, 0);
        checkInstant(253402300798L, 999999999);
        checkDuration(0, 0);
        checkDuration(-1, 1);
        checkDuration(-3601, 1000000);
        checkDuration(3601, 1234567);
        Random random = new Random(809221L);
        for (int i = 0; i < 12000; i++) {
            checkInstant(-62135500000L +
                 (long) (random.nextDouble()*315000000000L),
                 random.nextInt(1000000000));
            checkDuration((long) (random.nextDouble()*3000000000L) -
                1500000000L, random.nextInt(2000000000) - 1000000000);
        }
        checkDurationEdges();
    }
}
"""


class Java8BootInstantDurationTest(unittest.TestCase):
    def test_instant_duration_reference(self):
        if not shutil.which("javac") or not shutil.which("java"):
            self.skipTest("JDK unavailable")
        with tempfile.TemporaryDirectory(prefix="jarbox-java8-instant-") as temp:
            root = Path(temp)
            dest = root / "jarbox" / "compat" / "time"
            dest.mkdir(parents=True)
            paths = []
            for name in ("Instant", "Duration"):
                source = (TIME_SRC / (name + ".java")).read_text(encoding="utf-8")
                source = source.replace(
                    "package java.time;",
                    "package jarbox.compat.time;\n"
                    "import java.time.LocalDate;\nimport java.time.LocalTime;",
                    1,
                )
                file = dest / (name + ".java")
                file.write_text(source, encoding="utf-8")
                paths.append(str(file))
            fixture = root / "TestJava8InstantDuration.java"
            fixture.write_text(FIXTURE, encoding="utf-8")
            classes = root / "classes"
            subprocess.run(["javac", "--release", "8", "-d", str(classes)]
                           + paths + [str(fixture)],
                           check=True, capture_output=True, text=True)
            subprocess.run(["java", "-cp", str(classes),
                            "TestJava8InstantDuration"],
                           check=True, capture_output=True, text=True)


if __name__ == "__main__":
    unittest.main()
