# Ninja School (NSO) family Deep Treo — phase 1

## Actual three-JAR comparison (2026-11-21)

This profile is **not SHA-256 locked**. The three user-provided NSO builds are:

| JAR | SHA-256 prefix (documentation only) | NSO Canvas | Game loop |
|---|---|---|---|
| `NinjaSchool_251.jar` | `96f811dc1317` | `main/b.paint` | `main/a.run` |
| `217_TrungDucTV_51026.jar` | `3420df8cb91b` | `Class_ek.paint` | `Class_cu.run` |
| `Nick-B25-Map37-Farm-Clean-CPU.jar` | `7e1cff13508f` | `Class_hef.paint` | `Class_hxb.run` |

All three contain all seven common, non-empty NSO assets:
`font/number`, `font/tahoma_7`, `map/1`, `map/newmap`,
`x1/bg/bg00.png`, `x1/export/0`, `x1/e/d00.png`.
All three `Canvas.paint(Graphics)` overrides are 9-byte forwarding-only
methods without exception handlers, using `aload_0; getfield; aload_1;
invokevirtual/invokestatic; return`. They have distinct class names, different
constant-pool indices, and Nick delegates through `NickCpuSleep`.

All three main loops perform simulation work and then call `repaint()`
and `serviceRepaints()`, with their own `Thread.sleep` pacing. No game loop
or data access is skipped by this profile.

`Avatar258.jar` fails the resource check and its Canvas paint does not match
the nine-byte forwarding shape; so it retains Universal Treo.

## Implementation (single workflow)

On JVM start, **once**, miniJVM's already-bundled `miniz` inspects ZIP filenames
for the common resource signature. NSO is recognized with at least **5 of 7**
markers, including at least one map marker and one sprite marker; this tolerates
small mod asset changes without requiring an identical JAR hash. No reading/decompressing game resources in
the Treo hot loop. When the package qualifies, the installed Java
`Canvas.repaint`, `serviceRepaints`, and `doPaint` call a native predicate
that checks the current object class is a direct Canvas subclass with a
9-byte simple paint delegate. Accept both original and interpreter-quickened
`getfield` and invocation opcodes. Cache classification on each loaded
`JClass`. Only while JarBox mode 8 is active can the work be elided; keep
user-configured `limitFps`, game ticks, network, RMS, offscreen Images,
and mode-exit redraw path untouched.

In normal play, or on a non-NSO JAR, generic behavior is preserved. A future
NSO version lacking one of the assets or changing its Canvas.paint behavior
falls back safely (it can be explicitly added later based on new evidence).
A resource/name match by itself is **not** proof of identical game behavior,
so the Canvas method-shape check remains a minimal correctness gate, not a
full byte-for-byte method check.

The main logs remain `[JarBoxVM][NinjaDeep] profile=matched|generic`
and `[JarBoxVM][Treo]` fields `ninja_profile`,
`ninja_repaint_skips`, `ninja_service_skips`, `ninja_paint_skips`.
These labels are historical; now they represent the whole NSO family.

## On-device acceptance test

Build only **`J2ME Treo JIT probe unsigned`** on branch
`loader-ios-jit-probe`. Test each of the three JARs under the same scene
with JarBox Treo mode 8; keep any in-game Treo OFF. Collect the log and check
repaint/service skip counts, paint CPU, overall CPU, GC, network/auto,
map/mob activity, save state, and reawakened screen/inputs. On every JAR,
`ninja_profile=matched` plus skip counts >0 demonstrates activation, **not**
correctness or battery power saved. Compare CPU with a matched generic
baseline from the same workflow in a later commit, not a second workflow.

**Status:** static review and user-JAR bytecode comparison completed.
No new Codemagic build or iPhone functional/CPU A/B is yet verified.


## HUD mode name and game-loop heartbeat proxy (2026-11-21)

The black Treo screen now clearly displays **`Chế độ treo: Chuẩn`** or
**`Chế độ treo: Chuyên biệt (NSO)`**. "Chuyên biệt" is shown only for requested
JarBox mode 8 with an NSO resource-family match **and** a real loaded Canvas
matching the inspected simple paint-forwarding structure. The label
automatically refreshes with the existing 15-second status timer, without
adding a new UI timer, and leaves the diagnostic workflow titles alone.

New lightweight `[JarBoxVM][GamePulse]` log and result text include:

- `pre_8s_hz`: rate of NSO-qualified `Canvas.repaint()` requests in the eight
  preceding **full** one-second buckets, requiring at least six populated
  seconds. The snapshot is taken just before entering Treo. `?` means a
  reliable pre-Treo baseline is unavailable.
- `treo_hz`: observed calls to this same request method per second during Treo.
- `rate_ratio`: Treo request cadence divided by the pre-Treo cadence.
- `requests`: qualifying Canvas repaint requests during the interval.
- `last_request_gap_ms`: elapsed time from latest qualifying request to
  exit; a gap >= 5000ms flags suspected stall.
- `status`: `nhip_yeu_cau_khung_hinh_on`,
  `nghi_cham_nhip` (rate below 85% of baseline),
  `nghi_ngung_nhip` (zero requests / very long idle gap),
  `chua_co_moc_truoc_treo`, or `khong_co_tin_hieu_chuyen_biet`.

These calls occur on each game's own update-loop path in the three inspected
NSO JARs, so this is a useful **game-loop heartbeat proxy**, more meaningful
than paint FPS or CPU alone. It is **not** direct instrumentation of game ticks,
auto farming, network socket success or server-side state progression. A loop
can continue requesting a frame while the actual task is stuck. Thus even a
normal rate ratio does **not** prove game progress: check farm/mob/map/RMS and
network behavior after exiting Treo. No watt measurement is implied.

Implementation uses native monotonic timestamps and a fixed set of 16
one-second atomic bins. No disk I/O in the loop, no Java bytecode modifications,
no PaintHot sampler, and no added foreground UI timer. Probe state is reset per
loaded MIDlet in `jvm_bridge_init`. The same `J2ME Treo JIT probe unsigned`
Codemagic workflow remains the ONLY workflow. This change is committed
for a **subsequent IPA**; any IPA already installed during the current user's
measurement retains its earlier log format until rebuilt.

**Verification:** source/static checks only, no Codemagic compiler output or
on-device NSO pace measurements have been received yet.


## Same-thread compute speed / QoS before-vs-during Treo (2026-11-21)

A device log reporting 13.1% app CPU and 25.5 NSO repaint requests/s is evidence of early paint elimination and ongoing loop request cadence, **not** a hardware E-core/P-core reading. Low CPU by itself does not mean game computation became slower or faster. iOS may reduce CPU frequency or change scheduling when a thread does less work.

To test the specific user's hypothesis **without switching Codemagic workflows**, JarBox now collects `[JarBoxVM][NSOCompute]`:

- Sampled in the very same eligible non-main NSO repaint-requesting pthread before and during JarBox mode 8, with an identity gate; a new JAR resets the gate.
- At most one fixed **60,000 dependent integer operations** benchmark per **5 seconds** per phase. No thread is created and no busy-loop runs continuously. No PaintHot method profiler is enabled.
- `samples_pre` and `samples_treo` (at least 3/6 needed), `cpu_ns_per_step` (CPU clock excluding sleep/wait), `wall_ns_per_step` (includes preemption), `cpu_slowdown` and `wall_slowdown` (during/pre), `thread_qos` (raw Darwin QoS values) and `status`.
- `nghi_giam_toc_tinh_toan` when CPU time per fixed step increases >30%; `nghi_tang_do_tre_lap_lich` when wall time increases >35% but CPU time increase <=15%; otherwise `khong_thay_giam_toc_ro`, with `chua_du_mau` if insufficient.

Interpretation: an increased CPU ns/step suggests lower effective compute throughput for this fixed-work probe; an increased wall/CPU ratio suggests scheduling delays. QoS changes describe **requested scheduler class**, not actual physical P-core/E-core assignment. The iOS app cannot reliably obtain real core type, MHz, or watts using these log counters. A valid game-loop `[JarBoxVM][GamePulse]` rate plus unchanged compute speed is more reassuring, but server tasks, inventory or auto still need to be checked directly.

### Next on-device check

Build the exact same **`J2ME Treo JIT probe unsigned`** workflow from the latest commit on `loader-ios-jit-probe` (one workflow). Launch one of the three NSO JARs. Let normal gameplay and auto run for **at least 25–30 seconds** before JarBox mode 8 to collect >=3 pre samples; Treo 3–5 minutes. Send `[JarBoxVM][NSOCompute]`, `[JarBoxVM][GamePulse]`, and `[JarBoxVM][Treo]`. Perform a follow-up run under comparable temperature, charging state, same scene and network. Do not assume a new native log field is present in an IPA compiled before this commit. Source-only instrumented; no claim that actual iPhone QoS or core assignment has been measured yet.


## NSO Deep Idle Display wait experiment (after 394.6s GamePulse/NSOCompute log)

Device observation supplied by the user for the previous build:
- `app_CPU=14.0%`, `paint_CPU=0.00 ms/s`, `ninja_profile=matched`;
  `10050` repaint requests elided over `394.6s`.
- `GamePulse` live `25.25` repaint requests/s, Treo `25.47` requests/s,
  ratio `100.9%`, last gap `19.24ms`.
- `NSOCompute`: same-thread CPU `7.909 -> 15.658 ns/step`
  (`1.980x`), wall `7.906 -> 15.839 ns/step` (`2.003x`),
  QoS `21 -> 21`. A slow-down in the fixed-work probe while game
  repaint requests remain stable may reflect CPU frequency/power management
  or core scheduling changes. **It does NOT determine P/E core identity,
  confirm lower energy draw, or prove real game/server progress.**
- 215 smart GC cycles, `13.71ms/s` CPU, 14.9 MiB heap peak, thermal
  nominal throughout; GC fallback not seen.

### What changed

The Java Display event loop already includes an event-driven sleep path:
`Display.runEventLoop()` can call native
`displayWaitIfUnchanged(generation, 250)` instead of repeatedly sleeping
approximately 16ms. Native input, `Display.setCurrent`, stop/exit and
`treo_render_set_afk_mode` send wake signals; the 250ms watchdog prevents
unbounded waiting. The native pthread condition wait uses
`jthread_block_enter/exit` so miniJVM GC treats the sleeping Display
thread as safely blocked.

JarBox now enables this **existing** path automatically only while its
mode-8 Deep Treo overlay is active, **and only** after an NSO-family JAR
and a structurally recognized live NSO Canvas have been observed.
Other MIDlets and the fallback Treo mode are unchanged. On wake/teardown
the wait is disabled before normal screen restoration; the same wake
mechanism unblocks any pending wait. No NSO update/tick sleep, network,
RMS, Canvas heartbeat, or QoS is modified.

A new `[JarBoxVM][DisplayIdle]` line in the existing Treo report includes:
- `enabled`: whether the new event-driven Display mode was armed.
- `display_polls` and `polls_hz`: actual Display event-loop polls/second.
- `waits` and `waits_hz`: native idle waits/second.
- `timeouts`, `wake_signals`, `gc_safe_waits`: bounded timeouts,
  notification wakeups and GC-safe waits.

Hypothesis: lower idle polling/wake rates might reduce scheduler activity,
CPU load and heat under sustained Treo. These are hypotheses, not measured
savings. Compare with the previous ~14% CPU NSO session in similar game
state and later do an A/B under controlled conditions if promising.

### Device acceptance

Build the **same single** `J2ME Treo JIT probe unsigned` workflow from
`loader-ios-jit-probe` and let NSO run visibly >=30s before mode-8 Treo.
Treo at least 3–5 minutes. Send `[Treo]`, `[GamePulse]`,
`[NSOCompute]`, **new** `[DisplayIdle]`, GC/heap/thermal, and note
whether auto/network and wake redraw actually worked. Look for:
`enabled=1`, substantially fewer `polls_hz`, waits/timeouts,
unchanged `GamePulse`, healthy GC and input responsiveness. If
`enabled=0`, investigate live-Canvas detection. If the game, GC, or
wake behavior regress, roll back this single experiment; keep the
already-measured presentation bypass.

**Source code is committed but has not been built/tested on iPhone in
this environment.**


## TrungDucTV mod JAR startup resilience fix (2026-11-21)

User reported tapping `217_TrungDucTV_51026.jar` exits JarBox's game screen
immediately. Direct offline examination of the **uploaded binary** established:

- Valid ZIP (no compression/CRC errors), `521` entries, `184` classfiles.
- Manifest `MIDlet-1: TrungDucTV,/icon.png,GameMidlet`; `GameMidlet`
  really extends `javax.microedition.midlet.MIDlet`.
- Every classfile has major version `52` (Java 8), unlike the original
  NSO 251 whose classes use version `45`. All 184 classfiles parse
  successfully with the host JDK `javap`.
- **162/184** classes, including `GameMidlet`, `Class_ek`, `Class_ep`,
  and `Class_cu`, contain a symbolic
  `java/nio/charset/StandardCharsets.UTF_8` field reference; many have
  injected Java SE-only method references (`java/net/Socket`, etc.).
  A reference in a constant pool does not prove its method is executed.

Concrete miniJVM robustness bug:
`minijvm/jvm/class.c:class_clinit` eagerly resolves **every** field
reference in a loaded class before running its static initializer.
When `find_fieldInfo_by_fieldref` returns `NULL`, the previous code
attempted the lookup a second time and then unconditionally dereferenced
`fi->_this_class` => native crash. It did so even for a field used only
in obfuscation/dead code. This is a **likely** launch crash mechanism;
there is not yet an iPhone native stack trace tying the report to it.

Fix: cache `NULL` for missing eager field references and continue
class initialization. Do not manufacture `StandardCharsets.UTF_8`,
silently replace I/O functions, or alter the JAR. Existing interpreter
`getstatic/putstatic/getfield/putfield` instructions already retry
unresolved fields at first **real** execution and throw Java
`NoSuchFieldError` if unavailable. Valid field references still use
the same eager prelink logic.

Second fix: `MIDletRunner.main` no longer catches a Java exception
and returns normally (which previously made `call_main` appear to
succeed and the Swift game screen dismiss). Startup and lifecycle
failures now print their Java throwable and propagate a
`RuntimeException`; native `call_main` reports a nonzero return and
Swift shows the existing launch failure alert. Missing MIDlet manifest
class also produces a failure rather than a silent normal exit.
`codemagic.yaml`'s **existing single workflow** now recompiles this
updated `MIDletRunner.java` into the bundled `j2me_api.jar`; adding
Java source without this step would have been ineffective.

**Tests performed:** ZIP integrity and all 184 classfiles parsed by
`javap`; source audit of eager field linking and native interpreter
`NoSuchFieldError` fallback; static GitHub branch/workflow checks.
**Not performed:** running this JAR under iOS miniJVM, validating the
original SIGSEGV root with a device stack trace, proving the mod reaches
its menu/network flow, or proving no other Java SE incompatibility.
If the mod still fails, send new `[MIDletRunner]` / `[JVM Bridge]`
startup logs or crash stack so the next unsupported operation can be
located. Avoid touching optimized NSO paint/render paths until confirmed.


## Game startup/exit resilience after "Game execution failed (1)" (2026-11-21)

**Observed from user device:** the previous field-linking fix stopped the
silent close but did **not** make the TrungDucTV mod launch successfully.
The iOS screen now reports `Game could not start — Game execution failed
(1)`. This means `MIDletRunner.main()` (or a nested startup call)
unwound with an exception. **The actual Java exception and its line are
not known yet**. Do not claim the JAR is now compatible.

The current follow-up change provides safer ownership and actionable errors:

1. **Exclusive process-wide JVM session.** A main-thread
   `jvm_bridge_try_begin_session()` gate is acquired before dispatching
   the worker; native screen/view callbacks are installed only after this
   gate is granted. The worker is the only owner allowed to release
   `jvm_bridge_finish_session()`, via a `defer` that runs after native
   cleanup on all error paths. New launches during an old JVM's startup,
   run or cleanup are rejected with a user-visible message rather than
   overlapping one non-reentrant global `g_jvm`.
2. **Startup timeout with user choice.** At 20s without a first game
   frame/native screen (if the placeholder remains), show **Continue
   waiting** or **Cancel game**, not just a log line.
3. **Graceful stop plus bounded UI rescue.** Back/Cancel sets the
   stop flag, signals Display to wake, and (after a 2s grace period)
   calls `thread_stop_all()` from a background queue only while the
   native session phase is running. If cleanup is still stuck after
   7s, the UI can dismiss. Crucially the JVM is **not freed** by that
   timeout: ownership remains with its worker and the gate blocks any
   new JVM until it safely tears down. If the native VM never returns,
   the app may still require a full process restart before launching
   another game; fabricating a "safe force reset" would risk UAF.
4. **Avoid unbounded forced shutdown hooks.** miniJVM
   `jvm_destroy()` previously unconditionally started Java shutdown
   hook threads and `thrd_join`ed them, even if the host had already
   asserted `collector->exit_flag` for shutdown. That can hang
   indefinitely. In this forced path it skips starting new hooks; the
   ordinary graceful path still runs them.
5. **Show actual Java failure.** A launcher-only native method
   `NativeBridge.reportLaunchError(String)` records the caught
   Java throwable class+message in a session-owned UTF-8 buffer and
   logs `[JarBoxVM][LaunchError]`. `GameViewController.runMIDlet()`
   now reads it **before** JVM destroy and includes
   `Lỗi Java: <class>: <message>` in the user-facing failure dialog,
   not just `Game execution failed (1)`. The launcher remains
   recompiled into `j2me_api.jar` by the **single existing**
   Codemagic workflow. Existing startup-timeout alerts are dismissed
   before presenting the final JVM error.

**Verification:** GitHub source checks for native/Swift/Java signature
consistency and exactly one Codemagic workflow. No actual iOS compile,
runtime execution or real crash stack trace verified. Next test:
rebuild newest branch commit; try the original NSO (to ensure no
regression), TrungDucTV, and repeated quick open/cancel/open. For a
`Game execution failed (1)` report, copy the new **Java error text**
and console `[MIDletRunner]`, `[JarBoxVM][LaunchError]` and
`[JarBoxVM][Lifecycle]`. Further Java SE API compatibility work must
be driven by that actual exception rather than arbitrary stubs.


### Additional verified class-loader bug: interface-method table

An independent defect was found in `class_load.c`: when parsing the
`CONSTANT_InterfaceMethodref` pool, the code used
`arraylist_get_value(clazz->constantPool.methodRef, i)` instead of the
distinct `interfaceMethodRef` table. This silently populated metadata
for the wrong method refs and left real interface refs uninitialized,
potentially causing later interface method resolution failures. It now
correctly indexes `interfaceMethodRef`. It affects generic miniJVM
correctness; it is not a game-specific bytecode hack.

Offline classfile inspection shows `217_TrungDucTV_51026.jar` has
interface method refs in 13 classes (23 references total). The
original NSO and the Nick mod also contain interface refs, so they are
negative regression controls for the patch. This is a definite static
bug fix, but it has not been proven to be the exact source of the
reported code-1 Java exception.

**Important:** the previously reported `Game execution failed (1)`
was on a build *before* the latest launch-error/ownership/interface
metadata fixes. The newest build should report the actual Java error
name/message if execution still fails. A successful compile or
classfile parse does not imply a modded JAR will run.


### TrungDucTV lifecycle NPE from 2026-11-21 device screenshot

The device alert now says:
`Game execution failed (1)` and
`Lỗi Java: java.lang.RuntimeException: MIDlet lifecycle failed: java.lang.NullPointerException`.
This is **not** a proven iOS native crash, and the previous classloader
fixes did not make the JAR launch successfully. The Java `runLifecycle`
error handler catches exceptions from any of:
`GameMidlet.startApp()`, `Display.runEventLoop()`,
`pauseApp()`, or `destroyApp(true)`. The original alert
did not preserve stage or stack frames.

Direct static disassembly of the uploaded JAR shows:
`GameMidlet.startApp()` simply calls
`Display.getDisplay(this).setCurrent(Class_ek.a)`.
`GameMidlet.<init>()` constructs `Class_ek` and `Class_cu`,
which links the paint delegate; a later rendering/lifecycle failure is
therefore plausible. `Class_cu.<init>()` also calls
`System.getProperty(...).indexOf(...)` without a NULL guard,
but **its obfuscated property key was decoded offline** from
`Class_fj.a(String)`: `microedition.platform` (test string
`RIM`). The native bridge already provides
`microedition.platform=Apple/iPhone`. Do NOT falsely claim that
this property is missing or patch it to an empty string.

The next build now adds `launcherDiagnostic(stage, failure)`:
`phase=startApp`, `phase=Display.runEventLoop`,
`phase=pauseApp`, `phase=destroyApp`, or
`phase=load/constructor`, plus Java exception class/message
and up to 6 source stack frames if supported. It retains the original
diagnostic when the Java launcher subsequently catches the wrapper
`RuntimeException`; before this fix it overwrote the useful inner
failure with `MIDlet lifecycle failed`. The existing error bridge and
Codemagic workflow transport this into the on-screen error alert.

This instrumentation does **not** itself fix the Java NPE, which
still requires a proven failing call site before making a targeted
compatibility change. Use the next screenshot's full `Lỗi Java`
line and the `[MIDletRunner]` stack trace for that.


### Reference-setter inlining compatibility experiment after precise NPE stack

The user's on-device failure is now located:
`phase=Display.runEventLoop; java.lang.NullPointerException |
Class_ek.paint(Class_ek:-1) | Canvas.doPaint(Canvas.java:268) |
Display.runEventLoop(Display.java:241)`.

Offline `javap -c -p` on the uploaded
`217_TrungDucTV_51026.jar` shows:

```java
Class_ek.paint(Graphics g) {
    this.b.a(g);  // NPE when Class_ek.b is null
}
Class_ek.a(Class_bv delegate) {
    this.b = delegate;
}
GameMidlet.<init>() {
    Class_ek.a = new Class_ek();
    ...;
    new Class_cu().d();
}
Class_cu.<init>() {
    ...;
    Class_ek.a.a(this); // calls 6-byte reference-field setter
    ...;
}
GameMidlet.startApp() {
    Display.getDisplay(this).setCurrent(Class_ek.a);
}
```

The `Class_ek.a(Class_bv)` method is **exactly** the 6-byte
`aload_0 aload_1 putfield return` form that miniJVM's
`class_load.c:_changeBytesOrder` previously tagged as `is_setter`
and short-circuited with `_optimize_inline_setter`. The current
experiment makes **all reference-object setters** run through the
ordinary `invokevirtual` + `putfield_ref` bytecode machinery,
without touching primitive setter fast paths, Canvas semantics, NSO
Deep Treo mode 8, GC timing or the single Codemagic workflow.

This test isolates a possible discrepancy between miniJVM's inline
field-write shortcut and normal Java reference-field initialization.
The NPE definitively indicates that the delegate was null at first
paint, but **does not prove** the setter inliner was the cause. Do not
represent this patch as device-validated until the user builds a new
IPA and confirms that this exact mod draws its first frame and can
enter/exit game cleanly. If it still fails with the same stack, inspect
the object's constructor execution and field identity separately, and
consider more precise `Class_ek` bytecode field-write instrumentation.
Do not suppress/ignore NPE or silently skip the entire game paint.


## 2026-11-21: Persistent TrungDucTV first-paint NPE; VM layout fix and UI

User re-tested after disabling reference-setter inlining: the failure was **identical**:
`Game execution failed (1); phase=Display.runEventLoop;
java.lang.NullPointerException at Class_ek.paint -> Canvas.doPaint ->
Display.runEventLoop`. Thus the reference-setter shortcut experiment was
ineffective and has been **reverted**, avoiding uncertain performance loss
to other NSO/game code.

A more fundamental **general miniJVM correctness bug** was found in
`class.c:class_prepar`. It previously calculated
`clazz->field_instance_start = clazz->superclass->field_instance_len`
without ensuring the superclass had been prepared. A lazily loaded parent
may still have `field_instance_len=0`, causing class fields to overlap
inherited instance storage. Different JAR class initialization orders
can expose the bug. Fixed by recursively **preparing the superclass field
layout first** (without prematurely executing Java static initializers)
before laying out subclass fields. The existing PREPARING guard handles
reentrant preparation. This is a standards-aligned miniJVM fix, not a
hard-coded `Class_ek` workaround. It is a **candidate cause** for the
observed null delegate in paint, not yet device-confirmed.

Offline disassembly of the supplied `217_TrungDucTV_51026.jar`:
- `GameMidlet.<init>()` constructs `Class_ek`, stores it in
  `Class_ek.a`, then constructs `Class_cu`.
- `Class_cu.<init>()` calls `Class_ek.a.a(this)`.
- `Class_ek.a(Class_bv)` does `aload_0, aload_1, putfield b,
  return`; `Class_ek.paint` reads `b` and invokes `b.a(g)`.
- `GameMidlet.startApp` sets `Display.setCurrent(Class_ek.a)`.
- Only one external bytecode `putstatic Class_ek.a` was found among
  24 JAR classes mentioning `Class_ek` (GameMidlet constructor).
- Repeated first-paint NPE therefore indicates a missing/overwritten
  delegate by the time Canvas paint runs. The observed stack alone
  cannot distinguish incorrect field layout, missing setter invocation,
  or an unexpected class initialization/concurrency problem.

### Long-press game menu changes

`AppsListViewController.swift` now displays per-game menu item
`Đổi tên`, with an alert to save a **display-only** alias in
`UserDefaults` by stable JAR filename-derived game ID. The list sorts
and displays using this alias. Neither JAR path nor `Games Data` path
is renamed, so RMS/user save state is unchanged. Removing a JAR clears
the alias. Rename length is validated (1–80 visible characters).

The per-game long-press `Nâng cao` submenu contains the 3D
Enhancement toggle and FPS Limit menu; Screen Resolution remains
visible at the top level. **New per-game defaults** when no stored
preference exists: 3D disabled (render scale 1), FPS Unlimited (0).
Existing explicit preferences persist; FPS Unlimited does not disable
a game's own tick/pacing logic.

### Acceptance / caveats

Build from `loader-ios-jit-probe` using the one existing
`J2ME Treo JIT probe unsigned` Codemagic workflow. Test the original
NSO first, TrungDucTV second, and close/reopen games several times.
On failure, copy the unchanged/changed `phase` and full Java stack.
If first-paint `Class_ek` NPE persists after parent-before-child
field layout fix, next step is targeted **write/read instrumentation**
of the `Class_ek.b` field on the JVM thread to distinguish setter not
executed from field offset or object identity corruption. Do not hide
NPE, fabricate a delegate, or skip real paint to make the menu appear.

Source-level checks done; no on-iPhone or Codemagic build was run
during this change. Do not claim that the mod opens until verified.


## 2026-11-21 repeated first-paint NPE after superclass layout fix: targeted proof

The same `Class_ek.paint -> NullPointerException` stack recurred after the
parent-first class-field-layout patch. The live `Class_ek.b` reference is
null at the moment `Class_bv.a(Graphics)` would be invoked, but the stack
trace **does not** prove which earlier operation lost the reference.

The supplied `217_TrungDucTV_51026.jar` was examined with `javap`:
`Class_cu.<init>` invokes
`Class_ek.a(Class_bv)` at Java bytecode offset 36, then invokes
`System.gc()` at offset 227, and performs additional initialization.
`GameMidlet.<init>` constructs `Class_ek`, creates `Class_cu` and
calls its `d()` method before `startApp` invokes
`Display.setCurrent(Class_ek.a)`. Separate `Class_as` code reads
`Class_ek.b`, but those known references do not write it.

The newest **diagnostic-only** source adds a bounded
`[JarBoxVM][NSOInit]` field-state trace. It is captured in the
on-screen launch failure alert as `NSOInit:`, copyable with the existing
**Sao chép lỗi** action. Native miniJVM probes observe:

- `cu_ctor_entry`: Class_ek canvas and delegate before constructor
  initialization
- `setter_before` / `setter_after`: the **inlined**
  `Class_ek.a(Class_bv)` operation, its receiver, argument and field value
- `setter_bytecode_entry` / `setter_bytecode_exit`: the corresponding
  ordinary bytecode-execution path if miniJVM did not inline the setter.
  One pair or the other should appear if the intended setter executed
- `before_gc` / `after_gc`: delegate state immediately before and after
  `System.gc()` in the `Class_cu` constructor (without disabling GC)
- `cu_ctor_exit`: after constructor initialization including `System.gc()`
- `midlet_ctor_exit`: after creating and initializing `Class_cu`
- `paint_entry`: the Canvas object and delegate immediately before the
  failing paint

The trace includes `canvas` pointer, `static` Canvas pointer,
`b` delegate pointer, setter `arg` pointer, instance field offset,
class instance length and `valid` field-range check. These are
diagnostic values (not game data); do not infer identity when pointers
were not resolved. A bounded 12-event launch buffer is reset between
sessions, with no extra sampling on normal repaint/AFK paths.

Interpretation:
- `setter_after.b=null` despite non-null `arg` suggests a JVM write
  or field-offset/dispatch issue.
- `setter_after.b=non-null` and `cu_ctor_exit.b=null` points to
  intervening initialization or GC.
- `cu_ctor_exit.b=non-null`, `midlet_ctor_exit.b=null` points to
  code after Class_cu initialization.
- `midlet_ctor_exit.b=non-null`, `paint_entry.b=null` points to
  Display/Canvas handling, GC, or instance identity mismatch.
- `paint_entry.canvas != paint_entry.static` shows paint of a different
  Canvas instance from the one stored in Class_ek.a.

**This does not yet repair the actual NPE.** It isolates its origin with
one on-device launch instead of another speculative miniJVM modification.
The earlier setter-inlining and parent-layout patches did not change the
user-visible first-paint failure; the setter-inlining experiment has
already been reverted. Do not silently skip the paint, create a fake
delegate or add a hard-coded JAR-specific object assignment.

Source changes restricted to `loader-ios-jit-probe`, preserving the
single `jit-probe-unsigned` Codemagic workflow, NSO Deep Treo, 3D/FPS
advanced menu and display-only rename. No iOS build/device verification
has been done for the new probes.


## 2026-11-21 Library heat at 0–2% app CPU; low-power springboard background

User reported the phone feeling hot while sitting on the JarBox game
library although the reported **app CPU is about 0–2%**. This is not
proof of a JarBox thermal issue, nor evidence it is caused by CPU
execution. App CPU accounting does not directly measure display power,
the compositor, GPU power or skin temperature.

Source audit found the visible library's `AnimatedBackgroundView`
retained **six independently repeating UIKit view animations**, each
randomly moving/resizing over 10–16s, underneath a **full-screen
`NeutralBlurView(radius: 40)`** using live backdrop blur. This can
require repeated screen compositing/filtering even when the application
CPU percentage looks low. That is a concrete candidate for GPU/display
energy and heat in idle library mode.

To test/remove the ongoing work, the default library background
implementation is now a **static, opaque, cached gradient bitmap**:
- The six colors remain as smoothly blended radial gradients.
- Drawn once on initial screen layout, and rebuilt only if screen
  size or scale changes; backing-store scale capped at 2x.
- One UIImageView displays the result. No `UIView.animate`, live
  `UIVisualEffectView`, `CAFilter`, recurring blur, or timed loop on
  the home screen.
- The original animated implementation is preserved, **only** when
  building with the existing `JARBOX_BG_ANIM_BASELINE=1` Codemagic
  flag for controlled A/B tests. No new workflows are added.
- `[JarBoxBG] mode=static_bitmap` logs cached pixel size, bitmap render
  count and the absence of animated layers when the screen appears or
  game starts. `[JarBoxBG][Idle]` logs the OS-level thermal status,
  `UIScreen.main.brightness`, whether idle timer is disabled,
  current `jvm_bridge_session_phase()`, and background layer count.
  Logs are event-driven (appear, app active, thermal-state changes),
  **not** a per-second sampling timer.

A high brightness level, charging, unrelated system activity, cellular
radio, ambient conditions or an old JVM session stuck in cleanup may
also contribute to felt heat. These logs cannot attribute heat to
any specific part of the phone or measure watts/GPU utilization. To
validate, compare original animated background (baseline flag on)
against default static background under similar brightness, ambient
temperature, charging state, and idle library duration (e.g. 10–15min).
Check whether thermal state changes and how the physical temperature
feels; optionally use external power/thermal instrumentation. Do not
claim a battery saving without controlled device readings.

### New evidence from the user's exact NSO initialization trace

User reported:

```
NSOInit: midlet_ctor_exit:canvas=0x11f1a1f80,static=0x11f1a1f80,b=0x0,
arg=0x11f639100,off=112,len=136,valid=1 |
paint_entry:canvas=0x11f1a1f80,static=0x11f1a1f80,b=0x0,
arg=0x0,off=112,len=136,valid=1
```

Interpretation: the paint receiver **is the same instance as** the
canonical `Class_ek.a` canvas, and the `Class_ek.b` field is null
after the GameMidlet constructor and at first paint. The reported field
offset 112 is within the 136-byte instance field area. This rules out
the mistaken-Canvas hypothesis for that run. **Notably missing**
`cu_ctor_entry`, `setter_before`, `setter_after`,
`cu_ctor_exit`, and `before_gc/after_gc`. This strongly suggests
the initializer was not entered or those probes did not run; it is
**not yet proof** that GC or field corruption occurred. The next
instrumentation follows the actual GameMidlet bytecode path and logs:

- `new_cu`: object allocation from `GameMidlet.<init>`
- `special_resolve`: resolves its `invokespecial Class_cu.<init>`
- `special_execute`: dispatches the resolved class initializer
  before calling `execute_method_impl`
- `cu_ctor_entry` and the setter / GC probes as before.

To limit costs in all other games and in normal NSO Deep Treo, these
launch diagnostics activate **only** when the JAR contains all three
specific class paths (`GameMidlet.class`, `Class_cu.class`,
`Class_ek.class`) and matches the NSO resource family. The check
uses the already-open JAR ZIP reader at launch, never in game ticks.
The bounded trace now retains up to 20 short events in 4 KiB, and
the native method-entry path tests only one atomic flag when
instrumentation is off. On the next failure use **Sao chép lỗi** to
send the `NSOInit` section.

If `new_cu` is absent, GameMidlet's constructor control flow is
unexpected; if `new_cu` exists but `special_resolve` / `execute`
do not, investigate the invocation instruction transformation; if
resolution shows `actual_cls` other than `Class_cu`, inspect
miniJVM methodref binding and empty-method rewriting before changing
any other code. If `Class_cu.<init>` truly executes, field-write
events distinguish the actual failure.

No generic constructor or field semantics were changed in this
diagnostic patch. No on-device run of this version yet.


## 2026-11-21 repeated Class_ek NPE: underlying swallowed constructor exception discovered

The user's new run reproduced the **identical** Java NPE and NSOInit states:
`midlet_ctor_exit:canvas=static,b=0,off=112,len=136,valid=1`;
`paint_entry:canvas=static,b=0,...`, with **no**
`new_cu`, `special_resolve`, `special_execute`,
`cu_ctor_entry` or setter events. This confirms the Canvas is consistent
and the expected `GameMidlet.<init>` bytecode (which must reach
`new Class_cu` at offset 27, `invokespecial` at 31, `d()` at 34)
has **not been observed**. The old `midlet_ctor_exit` event logged
every function exit, including exception unwinding, and was misleading.

A **confirmed JVM correctness bug**, directly relevant to this pattern,
was found via native source audit:

- `jni_std.c:java_lang_Class_newInstance` called
  `instance_init(ins,runtime)` then **always pushed and returned the new
  instance**, even if its Java `<init>` threw.
- `jvm_util.c:instance_init_with_para` called
  `execute_method_impl(<init>)` and then only
  `print_exception(runtime)` when it failed; its `void` wrapper did
  **not return the exception status**.
- `MIDletRunner.main` uses `clazz.newInstance()`. If
  `GameMidlet.<init>` fails at an early class initializer, network
  setup, method resolution or unsupported Java API, this swallowed
  exception can result in an apparently created MIDlet with
  `Class_ek.a` already set and `Class_ek.b` still null; the secondary
  NPE then happens during `Display.runEventLoop`.

A generic miniJVM **semantic fix** was committed:
`instance_init_checked` runs the Java default constructor and returns
`RUNTIME_STATUS_EXCEPTION` with the **original Java Throwable still on
the operand stack**. `java_lang_Class_newInstance` now propagates that
status instead of returning a partially initialized object. Existing
legacy `instance_init/instance_init_with_para` APIs are not changed in
this patch. If a zero-argument constructor cannot be found,
`NoSuchMethodError` is propagated instead of dereferencing null.

The launch diagnostics now also include
`midlet_ctor_result:status=N,pc=OFFSET,code_len=L` and
`cu_ctor_result:status=N,pc=OFFSET,code_len=L`.
`pc` is the actual converted-method bytecode offset when in range;
a constructor returning via an exception can now be distinguished from
normal return. The expected next failure report is likely
`phase=load/constructor` with the **original Throwable and stack**,
not another first-paint `Class_ek.b` NPE. If so, debug the exact
constructor failure; do NOT blindly stub the implicated Java API.

**Important honesty:** this is a verified flaw in generic JVM
constructor exception propagation, and it is consistent with the
observed early-null Canvas state. It is not yet proven to be the *only*
or final reason the TrungDucTV mod cannot start; a new on-device build
is required to identify the original thrown error (or to confirm a
constructor dispatch bug if status/PC do not show an exception).

No JAR contents, game loop, paint/Deep Treo semantics, general-purpose
class layout, library background optimization, 3D/FPS preference,
rename, or Codemagic workflow count was changed by this fix.


## 2026-11-21 Class_fq receiver corruption identified and low-power solid gray UI

On-device diagnostic for TrungDucTV after the checked constructor patch:

```
phase=load/constructor; java.lang.NoSuchMethodException: a
midlet_virtual_miss:recv=java/lang/ClassNotFoundException,ref=Class_fq.a(LClass_bz;)V,slots=1,prelinked=1,pre_owner=Class_fq
midlet_missing_method:pc=20,op=182,ref=Class_fq.a(LClass_bz;)V
```

Direct inspection of the supplied JAR with `javap` confirms the
`public final void Class_fq.a(Class_bz)` method exists and PC 20 really
is that `invokevirtual`. The receiver is **not** `Class_fq` but a
`ClassNotFoundException` left on the shared operand stack. This is why
method dispatch failed despite successful symbolic prelinking.

Source audit of `class_load.c:load_class()` found a concrete stack bug:
when the application class loader's Java `loadClass` threw, the helper
returned NULL and left the thrown exception on the shared JVM stack.
Unreachable Java-8 method references can trigger speculative class loads
during `class_clinit` method prelinking, contaminating the active Java
method's operands. The new generic cleanup restores the operand-stack
depth of `load_class()` after the nested classloader call. It does not
invent a class, skip a game call, or change JAR contents. Whether this
is the final cause of the observed run **requires new on-device testing**.

The library appearance was simplified to a single opaque dark-gray view:
no gradient bitmap, blob animation, blur, or transparent navigation-bar
compositing. Missing game icons use a plain gray fill and icon press
feedback is immediate rather than animated. N-Gage decorative blur/glow
and per-frame mirrored game-image callback were removed; the actual game
Canvas is unchanged. No changes to main, bundled JAR games, NSO Deep
Treo mode 8, or the single Codemagic workflow.

Next: build latest `loader-ios-jit-probe`, test NSO 251 control and
TrungDucTV, and send the full new `Lỗi Java` plus `NSOInit` if it still
fails. Also compare 10-15 minutes of idle library CPU/thermal at fixed
brightness/charging conditions. Static checks and GitHub commit do not
constitute a successful iOS build/device runtime test.
