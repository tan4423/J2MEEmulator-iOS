# JarBox Java API Compatibility Audit

This read-only analyzer identifies potential missing external Java class, method,
and field references by comparing a game JAR's bytecode with the *actual*
JarBox runtime JARs. It does not execute any game code and never edits JARs.

Use Java 17+ for the optional test fixtures, Python 3.9+ for the tool.

```sh
python3 tools/jar_api_audit.py \
  --boot J2MEEmulator/Resources/jars/minijvm_rt.jar \
  --api J2MEEmulator/Resources/jars/j2me_api.jar \
  --output /tmp/jarbox-api-report.json \
  /path/to/game.jar

python3 -m unittest discover -s tools/tests -p test_jar_api_audit.py
```

Run against the **post-patch JARs** to include compatibility classes inserted by
Codemagic, such as StandardCharsets and LocalTime. A report against bundled
pre-patch files will overestimate missing APIs. To generate a post-patch report
inside the existing workflow, optionally set `JARBOX_COMPAT_AUDIT_JAR` to
an existing **local file path** available to the build, not an external URL.
No user JAR is uploaded and the report is not a build gate.

The inventory reports referenced external classes, missing class definitions,
missing method descriptors and missing fields. Inherited methods/fields are
checked. It deliberately does not fail builds for unused code references,
reflection, dynamically loaded classes, native calls, incomplete ancestor
hierarchies or behavioral differences. The tool does not address arbitrary
bytecode rewrites or version-specific game checks.

Prioritize implementing missing APIs in a shared, tested boot/J2ME runtime layer,
not adding game-specific bytecode patches. Use the working TrungDucTV build
as the regression baseline. Never alter the original JAR, the main branch,
Deep Treo behavior or session-token lifecycle to satisfy an audit warning.


## iOS VM containment for unsupported instructions

The upstream interpreter's fallback for unknown/unsupported JVM opcodes
invokes `exit(2)`; a game encountering one would terminate JarBox itself.
On iOS only, both the ordinary opcode and the `wide` sub-opcode fallback
now push `java.lang.VerifyError` onto the Java operand stack and unwind
through the existing exception handler instead. A trace note records
`vm_unsupported_opcode:class=...,method=...,pc=...,opcode=...`
without disclosing network content. A compatible VerifyError class is
compiled into the boot runtime and checked by classfile path during build.
This does **not** make that opcode supported or fix all possible native
crashes; it allows the normal Java error path to run without calling
`exit(2)`. Other OS builds retain the original interpreter path.


## Java 8 boot utility compatibility (2026-11-21)

JarBox patches the **boot** `minijvm_rt.jar` at build time with two
dependency-light Java utility classes. The shipped game JARs remain byte-for-byte
unchanged; there is no mod-specific runtime bypass.

- `java.util.Base64`: Basic, URL-safe and MIME array/String encode/decode,
  optional padding, MIME line wrapping, custom MIME separators, and
  encode/decode into caller-provided byte arrays. Output and invalid-input
  handling follow the Java 8 Base64 conventions.
- `java.util.Objects`: `equals`, `deepEquals` (object and primitive arrays),
  `hashCode`, `hash`, `toString`, `isNull`, `nonNull`,
  `requireNonNull` (plain and String message), and `compare`.

**Subset boundaries:** Base64 ByteBuffer conversions, InputStream/OutputStream
wrappers, and the `Objects.requireNonNull(T, Supplier<String>)` overload are
not yet implemented. This is **not** full Java SE 8 compatibility; libraries
that depend on other classes or Java language features may still fail.
Neither class is a network protocol workaround.

Run `python3 -m unittest discover -s tools/tests -p 'test_*.py'` to
exercise the host-JDK comparison fixture. Codemagic compiles the original
`java.util` sources at `--release 8`, inserts *all* their classfiles into
the boot JAR, and inspects extracted bytecode signatures by exact file path
(including `Base64$Encoder` and `Base64$Decoder`). The packaged IPA records
`boot_patch=java8_utf8_localtime_verify_util_v4`; compare the
`build_commit` fingerprint when reporting iPhone results.

Local `javac --release 8` compilation and comparison against the host JDK
passed for 256 randomized lengths plus 9 fixed vectors over Basic, URL,
unpadded, MIME, and custom-line-break cases, alongside invalid input checks
and null/deep-equality helpers. This is a host-only regression result,
**not** an iOS build or real iPhone execution result.

Next validation: use the existing single Codemagic workflow and verify that
the original Ninja School and the working TrungDucTV mod still open and play,
then test a separately supplied Java 8 utility-using JAR. Avoid claiming that
all Java 8 JARs are supported based only on one working mod.


## ISO LocalDate / LocalDateTime boot compatibility (2026-11-21)

User confirmed the previous Java 8 Base64/Objects IPA still runs the tested
games normally. Preserve that working build as a regression baseline.

Two additional immutable Java 8 **subset** classes are now compiled into
`minijvm_rt.jar` at build time:

- `java.time.LocalDate`: `now()` (device-local Calendar),
  `of(year,month,day)`, `ofYearDay`, ISO `parse(CharSequence)`,
  `ofEpochDay`, `toEpochDay`, month/year lengths, leap years,
  `getYear/getMonthValue/getDayOfMonth/getDayOfYear`,
  `plus/minusDays/Weeks/Months/Years`, selected `with...` methods,
  ordering, value equality, hashing and ISO output.
- `java.time.LocalDateTime`: `now()` from one Calendar snapshot,
  `of` component overloads and `of(LocalDate,LocalTime)`, ISO
  `parse(CharSequence)`, date/time component getters, date/time
  `with...` methods, `plus/minusDays/Weeks/Months/Years` and
  `plus/minusHours/Minutes/Seconds/Nanos`, ordering, equality,
  hashing and ISO output.

The subset deliberately **supports ISO years 0001–9999 only**; Java SE 8
accepts a larger range. It has no `java.time.temporal` framework, timezone
rules, `Instant`, `ZoneId`, `DateTimeFormatter` overloads, or full
JDK exception taxonomy. Invalid date/time operations currently throw
`IllegalArgumentException` or `NullPointerException` where appropriate;
this is not exact JDK exception-class equivalence. `LocalDateTime` is a
zone-free wall-clock value. Neither type forges clocks, adjusts server
packets, or changes any game JAR.

Offline verification: `javac --release 8` compiled the source classes
with Java 8 classfile signatures. An isolated, package-renamed host fixture
compared 3,004 ISO date examples and 3,002 date-time examples (including
randomized dates/times, leap-year/month rollover, epoch-day conversions,
parsing, addition/subtraction, equality and hashes) against the host Java
implementation; the checks passed. The host fixture uses JDK `LocalTime`
for the renamed `LocalDateTime` class, not a real miniJVM runtime.
Codemagic now executes `test_java8_boot_dates.py` via the existing
`test_*.py` discovery, compiles the actual `java.time` classes to the
boot JAR, extracts them by exact classfile path, and verifies method
signatures and use of CLDC `Calendar.getInstance()`.

IPA version stamp: `boot_patch=java8_utf8_localtime_date_v5`.
Do not claim an actual iPhone result until this exact build is installed
and tested. Recheck original NSO and TrungDucTV launch, gameplay, session
stop/restart, and background behavior. No changes to the single Codemagic
workflow count, `main`, Deep Treo, JVM session token, or game content.
