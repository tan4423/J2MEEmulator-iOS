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
