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


## Java 8 Instant / Duration boot compatibility (2026-11-21)

The user confirmed the preceding `LocalDate` / `LocalDateTime` IPA runs
their tested games normally. Preserve that on-device result as the regression
baseline. This update adds two further *generic* Java 8 boot-library subsets:

- `java.time.Instant`: `EPOCH`, `now()` from `System.currentTimeMillis()`,
  `ofEpochSecond(long)`, `ofEpochSecond(long,long)`,
  `ofEpochMilli(long)`, `getEpochSecond`, `getNano`,
  `toEpochMilli`, `plus/minusSeconds/Millis/Nanos`, comparison,
  equality/hash, ISO UTC formatting and strict `Z`-suffixed
  `parse(CharSequence)`. Instants are immutable and normalized to 0..999999999
  nanoseconds. The time is UTC; no fake clock, server status, local-zone
  adjustment, JAR edit or game-specific code is involved.
- `java.time.Duration`: `ZERO`, `ofSeconds` (both forms),
  `ofMillis/ofNanos/ofMinutes/ofHours/ofDays`,
  `getSeconds/getNano`, sign/zero checks, `toDays/Hours/Minutes/Millis/Nanos`,
  `plus/minus` of Duration and of seconds/millis/nanos/minutes/hours/days,
  `negated`, `abs`, comparison, equality/hash and ISO `toString`.
  Arithmetic uses explicit overflow checks and the Java 8 negative-fraction
  second/nanosecond representation.

**Boundaries:** `Instant` deliberately limits UTC calendar years to
0001–9999, matching JarBox's `LocalDate` subset (unlike full JDK Instant).
Its parser supports only UTC `Z` timestamps with mandatory seconds,
optional 1–9 digit fraction; not timezone offsets or a general formatter.
`Duration.parse`, `Duration.between(Temporal,Temporal)`, Temporal/ChronoUnit,
clock/zone providers, streams, `BigInteger` and the full `java.time`
interface ecosystem are not implemented. Some invalid values throw
`IllegalArgumentException` rather than the exact JDK date exception.
Supporting these classes alone does not make arbitrary Java 8 JARs runnable.

**Host validation:** exact Java 8 source compiled at `--release 8`.
A package-renamed, host-JDK regression checked over **12,000 randomized
Instant samples and 12,000 randomized Duration samples**, plus fixed boundary
vectors, comparison of ISO output, epoch milliseconds, nanos, normalized
arithmetic, hash codes, negative fractional milliseconds, and extreme
`Long.MIN_VALUE` subtraction. The package-renamed fixture uses the host JDK
`LocalDate`/`LocalTime` for Instant formatting while the iOS boot runtime
uses JarBox's previously validated date/time subset. The build-time
test `tools/tests/test_java8_boot_instants.py` is included in the existing
`test_*.py` discovery.

**Build integration:** only the pre-existing Codemagic workflow compiles
`Instant.java` and `Duration.java` into `minijvm_rt.jar`, extracts exact
`java/time/Instant.class` and `java/time/Duration.class` paths, checks
the expected public methods and that `Instant.now()` calls the real system
millisecond clock. The IPA stamp is
`boot_patch=java8_utf8_localtime_instant_duration_v6`.
Codemagic and iPhone execution for this commit are **not yet verified**.
Retest original Ninja School and TrungDucTV gameplay and restart behavior
before treating the new IPA as a stable baseline. No changes to `main`,
Deep Treo, game JARs, network packets, or the session-token lifecycle.


## Java 8 Optional and functional interfaces (2026-11-21)

The user confirmed that the prior `Instant`/`Duration` v6 build still plays
their tested games normally. Preserve that device result as the baseline.

The v7 boot patch adds **generic library APIs**, not game-specific behavior:
`java.util.Optional<T>`, `java.util.function.Function<T,R>`,
`Predicate<T>`, `Consumer<T>` and `Supplier<T>`.

- Optional implements Java 8 `empty/of/ofNullable/get/isPresent/ifPresent`,
  `filter/map/flatMap`, `orElse/orElseGet/orElseThrow(Supplier)`,
  and Java 8 value equality, hashing and display. Null arguments follow
  the respective Java 8 method's lazy/eager validation semantics.
- Function supports `apply/compose/andThen/identity`; Predicate supports
  `test/and/or/negate/isEqual`, with short-circuit evaluation; Consumer
  supports `accept/andThen`; Supplier supports `get`.
- Java 8 interface `default` methods use ordinary anonymous helper
  classes rather than lambdas, making these boot classes themselves free of
  the `invokedynamic` instruction. The build includes and checks the
  helper `.class` files; they must not be omitted from the boot JAR.

**Limitations:** This is not a complete `java.util.function` package,
`java.util.stream` API, or `OptionalInt/OptionalLong/OptionalDouble`.
The Java 9+ no-argument `Optional.orElseThrow()` and other post-Java-8
methods are not included. The presence of these interfaces does not prove
that the miniJVM runtime can execute arbitrary Java 8 lambda expressions,
method references, or all interface-default-method dispatch paths on iOS.
Those JVM instruction/dispatch capabilities require separate device testing.

**Validation:** The original sources compile with `javac --release 8`.
Host JDK comparison tests use package-renamed sources so the host's
`java.base` classes cannot silently substitute for the new classes.
`tools/tests/test_java8_boot_optional.py` exercises 2,003 Optional
null/non-null string vectors, mapping, flat-mapping, fallback, exceptions,
equality/hashing, function composition, predicate short-circuiting, and
consumer ordering. This test is included in the existing single Codemagic
workflow's `test_*.py` discovery. The final IPA boot JAR includes exact
classfile checks, including anonymous helper classes.

`boot_patch=java8_optional_function_v7`; Git build SHA is still stamped
independently into the IPA. There is **no new workflow** and no change to
`main`, Deep Treo fast paths, session tokens, game JARs, or packet/network
logic. Codemagic/iPhone verification for v7 has not yet been performed.
Retest launch/play/restart on original NSO and TrungDucTV; ideally also run a
small MIDlet that uses `Optional.map` and `Function.andThen` to validate
the miniJVM's on-device interface dispatch.


## Java 8 primitive Optional and callbacks (v8, 2026-11-21)

The previous `java8_optional_function_v7` build was confirmed by the user to
play their tested JARs normally. This is a *regression baseline*, not proof of
full Java SE 8 coverage.

The boot compatibility runtime now additionally contains:

- `java.util.OptionalInt`, `OptionalLong`, `OptionalDouble`, implementing the
  **Java 8** methods `empty`, `of`, `getAsInt/getAsLong/getAsDouble`,
  `isPresent`, `ifPresent`, `orElse`, `orElseGet`,
  `orElseThrow(Supplier)`, `equals`, `hashCode`, and `toString`.
  These are actual value containers with lazy callbacks; not fixed return
  values, network bypasses, or rewrites of game code.
- `java.util.function.IntConsumer/LongConsumer/DoubleConsumer` including
  `andThen`, and `IntSupplier/LongSupplier/DoubleSupplier`.
  The callback classes are compiled to Java 8 classfiles; their `andThen`
  helpers are included as separate anonymous `$1.class` files.
  `OptionalDouble.equals` and `hashCode` use `Double.doubleToLongBits`
  so NaN values compare as Java 8 specifies and signed zero stays distinct.

Host JDK 21 compiled the exact standalone classes using `--release 8`, and
a package-renamed fixture compared 5,000 random values **per primitive**
plus edge cases to Java's standard `OptionalInt/Long/Double`; all passed.
Host behavior verification is *not* miniJVM or iOS execution verification.
The repository test `tools/tests/test_java8_boot_primitive_optional.py`
is run by the pre-existing Codemagic `test_*.py` test discovery before
building the iPhone IPA. The workflow extracts the exact boot classfile
paths, checks Java 8 method signatures, and checks all three `Consumer$1`
helper classes. The build stamp is `java8_primitive_optional_v8`.

**Size/performance:** the 12 new classfiles have a total uncompressed
size of approximately 11.6 KB in local Java 8 compilation. The net IPA
difference was not measured. These utilities contain no background work,
GPU draw commands, networking, or timers; game CPU usage may nevertheless
change when a game executes a new method frequently, and class loading uses
RAM and startup work. No claim of zero overhead or identical FPS is made.

**Not full Java SE 8:** `OptionalInt/Long/Double.stream`, `isEmpty`,
no-argument `orElseThrow`, `ifPresentOrElse` and similar later-Java
methods are intentionally not added. `java.util.stream`, every primitive
functional-interface specialization, generic lambda/invokedynamic and
interface dispatch across arbitrary JARs remain separate compatibility
work. This upgrade adds APIs on the boot classpath; it does not alter
`main`, JAR files, server responses, Deep Treo, the JVM session token,
rendering/audio engines or the number of Codemagic workflows.

**On-device validation needed:** build the existing
`J2ME Treo JIT probe unsigned` workflow from the HEAD of
`loader-ios-jit-probe`, verify that the diagnostics show the matching
`build_commit` and `boot_patch`, then play Ninja School and TrungDucTV,
close/reopen each game, and optionally run a small MIDlet that calls the
new primitive APIs and `andThen` to test default-method dispatch in miniJVM.


## Java 8 functional-interface completion (v9, 2026-11-21)

The user confirmed the v8 Ninja School/TrungDucTV regression build runs
normally. This changes the **shared boot library only**, with no JAR-specific
branches, fake method bodies, server spoofing or revised JVM scheduling.

JarBox previously provided 10 Java 8 `java.util.function` interfaces.
`tools/generate_java8_function_boot.py` now generates **all remaining 33**,
covering exactly the **43 public interface names** in the Java 8 package:
BiConsumer/BiFunction/BiPredicate, BooleanSupplier, UnaryOperator,
BinaryOperator, typed primitive predicates/operators/converters/functions,
ObjInt/ObjLong/ObjDouble consumers, and ToInt/ToLong/ToDouble functions.
Where Java 8 specifies `compose`, `andThen`, `and`, `or`, `negate`,
`identity`, `minBy` and `maxBy`, the implementations perform real
composition, short-circuit evaluation and comparator calls rather than
returning dummy values. The runtime patch also completes the Java 8
`Objects.requireNonNull(T, Supplier<String>)` overload, with lazy
message evaluation.

The generator is deterministic: it emits public Java sources in the
build's temporary workspace, compiled with the existing boot patches at
`javac --release 8`. All generated classfiles and their anonymous helper
classes are inserted into `minijvm_rt.jar`; the existing single Codemagic
workflow checks the 33 generated classfile paths, key method signatures
and representative helper classfiles. The IPA fingerprint is
`boot_patch=java8_function_api_v9`.

**Verification boundary:** On a local host JDK 21, the generation compiled
successfully to Java 8 bytecode. A package-renamed test compared each of the
33 interface public method signatures to the host JDK's reference and ran
behavioral checks of compositions, order, primitive conversion, early null
rejection and predicate short-circuiting. The fixture also asserts generated
classfiles do not invoke `invokedynamic`. The committed regression test is
`tools/tests/test_java8_full_function.py`. This **does not prove** native
miniJVM iOS support for arbitrary default-interface-method calls or Java 8
lambda bootstrap execution; those must be tested with real on-device fixtures.

**Not all Java SE 8:** the remaining compatibility surface includes
`java.util.stream`, `java.util.Spliterator`, many `java.nio` classes,
additional `java.time`/formatting/zone APIs, Java reflection/loading
differences, default interface dispatch and `invokedynamic` behavior.
Completing all of Java SE 8 is not equivalent to shipping the
`java.util.function` package and cannot responsibly be claimed from these
tests. Use the existing read-only API auditor on supplied JAR files and
confirm the next missing class/method/field or VM operation on-device.

No changes to `main`, Deep Treo optimizations, game graphics/audio/network,
private-server version logic, original JAR content, or session-token teardown.
The number of Codemagic workflows remains one. Revalidate the v9 IPA on
Ninja School, TrungDucTV and ideally a small java.util.function fixture
before treating this version as the device regression baseline.


## Java 8 StringJoiner + newer JAR classfile profiling (v10, 2026-11-21)

The user confirmed the `java8_function_api_v9` IPA is working on their
games. Preserve v9 as the on-device regression baseline.

### Runtime API

The boot classpath now includes the **real Java 8 `java.util.StringJoiner`
surface** (both constructors, `add`, `merge`, `setEmptyValue`,
`length`, `toString`). It stores actual characters, keeps a snapshot
of delimiter/prefix/suffix, handles null elements using `"null"`, and
handles self-merging and empty joiners without special-casing game data.
No dummy method bodies or bypasses.

The host-side regression `test_java8_boot_stringjoiner.py` compiles the
original source as Java 8 bytecode in an isolated package and compares
2,000 randomized sequences of joins and merges against the host JDK.
It also checks empty values, null arguments, empty elements, self-merging,
Unicode, and mutable CharSequence constructor arguments.

### Static JAR bytecode profile

A separate, read-only command now reports whether a supplied JAR contains
Java 8/11/17+ classfiles and attributes requiring additional VM support:

```sh
python3 tools/jar_bytecode_profile.py --output /tmp/jarbox-bytecode.json \
    /path/to/mod.jar
```

The report identifies:
- Baseline classfile major versions, including **52=Java 8**, **55=Java 11**,
  **61=Java 17** (higher major versions are mapped mechanically).
- Optional multi-release JAR entries, separated from baseline classes.
- Static references such as invokedynamic, method-handle/method-type and
  dynamic constants, plus NestHost, NestMembers, Record, PermittedSubclasses
  and module classfile attributes.
- Where a BootstrapMethods attribute is present, referenced bootstrap owners
  (for example `java/lang/invoke/LambdaMetafactory` for Java 8 lambdas versus
  `java/lang/invoke/StringConcatFactory` for Java 11 string concatenation).
  These owners are static references, not a promise of runtime support.
- Invalid classfiles and preview classfile flags.

The profiler reads bounded classfile data and **never executes or changes**
a game JAR. Seeing an `invokedynamic` constant does not prove that it will
be executed, nor that the miniJVM supports its bootstrap. A Java 8 classfile
may also depend on missing JDK APIs or dynamically load classes not visible
to static scanning.

The existing optional Codemagic variable `JARBOX_COMPAT_AUDIT_JAR` now
runs both the old API-surface analyzer and this new bytecode profiler when
set to an existing **local JAR path**. No JAR is downloaded. Without that
variable, the workflow builds normally and runs only the small host regression
fixtures. The new tests compile Java 8 lambdas, Java 11 string concatenation
and Java 17 records and verify the reported classfile versions and feature
flags; they also cover truncated bytecode and multi-release archives.

**Not full Java 8/11/17 compatibility:** This v10 is a scoped library
addition plus analysis tooling, **not** a new JVM. It does not implement
`java.util.stream`, the whole NIO API, all `java.time` interfaces or
all modern Java class loading, default-method, LambdaMetafactory and
`invokedynamic` behavior. In particular, simply lowering a classfile's
major version is not a valid way to support newer Java bytecode.
Those capabilities require dedicated implementation and on-device testing
against the real mod JARs. Do not advertise arbitrary Java 11/17 JAR support.

The same single Codemagic workflow builds the extra classfile into
`minijvm_rt.jar`, extracts it by exact path, checks Java 8 public
signatures, and stamps
`boot_patch=java8_stringjoiner_profile_v10`.
No changes to `main`, JAR files, networking, graphics, Deep Treo,
the JVM session lifecycle, or normal game-loop instrumentation.
The v10 IPA must be built and verified on iPhone before calling it
an on-device stable baseline.
