# NST_X1.jar: MicroEmulator works, JarBox exits — static investigation

Date: 2026-11-21. Status: **root cause not confirmed; native iOS crash report required**.

## Artifact checked (not committed or modified)

- Original filename: `NST_X1.jar`
- SHA-256: `990eec91849372df93a9b845502baf13ab761c11bd8c1c6d2247a4831fc50acc`
- Compressed file size: 1,400,974 bytes; 534 ZIP entries; all entries readable.
- Manifest: `MIDlet-1: NST_X1,/icon.png,nso.GameMidlet`; `MIDP-2.0`, `CLDC-1.1`; `icon.png` exists.
- 193 `.class` entries, **all Java 8 classfile major 52** (minor 0).
- No constant-pool tags for `CONSTANT_InvokeDynamic`, `MethodHandle`, `MethodType`, `Dynamic`, `Module`, or `Package` in any of the 193 classfiles.
  Thus adding Java 11/17 classfile recognition or lambda API implementations alone does **not** explain this crash.

## Startup path from unmodified bytecode

`nso.GameMidlet.<init>` calls, among others:
- `y.ap()`, `new ci()` (Canvas), `bC.a()`, `bG.a()`,
  `bC.a(bG)`, `new a()`, `a.c()`, `new bW()`.
- Note: much of the game starts **inside the MIDlet constructor**, before
  `startApp()`. `a.c()` starts a Java thread.

`nso.GameMidlet.startApp()` subsequently calls `cq.in()` conditionally,
`cq.io()`, `B.aN()`, and sets the current Canvas.
`B.aN()` constructs a `Thread`, calls `Thread.setDaemon(boolean)`,
and starts the thread; this is a concrete early-runtime API call to verify.
`a.<init>` checks `System.getProperty("microedition.platform")` against
`"RIM"`. These two strings were statically decoded from the source JAR's
checksummed string literals (not from network data).
The JarBox native bridge currently supplies this property as `Apple/iPhone`,
so the property is not absent in that implementation.

## High-load/obfuscation characteristics

The JAR manifest declares `Created-By: AdvMenu Unpacker (By Quyetdaik)`.
Class names and method/field identifiers show extensive obfuscation, with
checksummed string/number array decryptors. Examples:

| Class | Uncompressed classfile size |
| --- | ---: |
| `bO.class` | 315,469 bytes |
| `bL.class` | 307,814 bytes |
| `aL.class` | 170,454 bytes |
| `bG.class` | 124,529 bytes |
| `B.class` | 79,229 bytes |

`bO.class` contains 630 fields and 383 methods; `bL.class` has
several obfuscated `$init_...` methods with bytecode lengths around
35 KB each. These large classes are valid Java classfiles but could stress
the miniJVM class loader, native heap, or interpreter, particularly during
synchronous startup. **This is a hypothesis, not a confirmed OOM/crash.**

## API references worth validating in JarBox's boot runtime

- `cq.class`: `java.io.File`, `FileOutputStream`,
  `PrintStream(OutputStream,boolean,String)` (logging code).
- `bu.class`: `java.net.URL` / `HttpURLConnection` and
  `java.nio.ByteBuffer.wrap(byte[])` (Java SE-style HTTP code).
- `B.class`: `String.format(String,Object[])` and
  `String.contains(CharSequence)`.
- `B.aN()`: `Thread.setDaemon(boolean)`.

The constant-pool references confirm these APIs are present in the JAR;
they **do not** show whether they execute before the crash or are present
in the bundled `minijvm_rt.jar`. Use `tools/jar_api_audit.py` with the
real final boot/API JARs to verify missing classes/members.

## Rejected premature diagnosis

`a.<init>` contains `multianewarray` for `Image[][]`, and
`interpreter.c` uses `class_get_utf8_string(clazz, cp_index)`.
Although `cp_index` names a `CONSTANT_Class`, the optimized miniJVM
constant-pool structs `ConstantUTF8.utfstr` and `ConstantClassRef.name`
share the same pointer offset, and `class_load.c` populates the name.
The observation **is not sufficient to claim a bug**. Do not change this
opcode implementation without a reproducer / native stack trace.

## Next evidence to obtain

1. On the same v10 IPA, test whether tapping NST_X1 quits the **entire
   JarBox iOS process** or merely returns to the game library; note if the
   screen ever renders.
2. Obtain an iOS `.ips` report for the matching launch from
   Settings → Privacy & Security → Analytics & Improvements → Analytics Data.
   Look for JarBox/J2ME Treo or `JetsamEvent`. The exception type,
   termination reason and crashed thread distinguish `SIGSEGV`, memory
   pressure, watchdog and managed Java errors.
3. If an `.ips` report is not generated, collect the Xcode Devices/Console
   process log around the launch, including the last
   `[JVM Bridge]` / `[JarBoxNET]` trace or JVM exception.
4. Run the existing read-only boot/JAR API auditor on the exact final
   patched boot JAR, then investigate the first missing method or native
   failure **in the generic runtime**, not by changing NST_X1.
5. Add minimal opt-in startup breadcrumbs or a small reproducer for the
   failing runtime operation only after the exception/crash site is known.

No game JAR, network response, build workflow, `main`, Deep Treo,
or JVM session lifecycle changes are authorized by this audit.
