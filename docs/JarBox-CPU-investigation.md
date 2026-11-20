# JarBox CPU investigation — verified observations and next architecture

Scope: J2MEEmulator-iOS on `loader-ios-jit-probe`. Optimize the emulator for original, unmodified JARs; never specialize the runtime for Avatar or Ninja. CPU % is app CPU time divided by wall time, expressed in single-core equivalents, **not watts**.

## Evidence ledger

| Experiment | Nick-B25-Map37-Farm-Clean-CPU.jar | Avatar258.jar | Interpretation |
| --- | --- | --- | --- |
| Guarded Canvas raster skip, A1/A2-compatible mean | 47.4% total CPU | 49.9% total CPU | Same JAR, same Java/GC/JIT state within each A/B/A |
| Guarded Canvas raster skip, B | 61.0% total; main 27.8%; paint 18.0% | 36.4% total; main 33.0%; paint 1.6% | Ninja **+13.6 CPU points**, Avatar **-13.5 CPU points**; therefore not safe to assume a universal energy benefit |
| GameCanvas framebuffer-copy elimination | 0 flushes, 0 copies, +0.6 CPU points in B | 0 flushes, 0 copies, -0.1 CPU points in B | No target work removed in either workload; not evidence for a useful optimization |
| Adaptive GC | Reported ~74% less CPU time spent **inside GC** in earlier audit | — | GC improvement is not equal to whole-app CPU or battery reduction |
| Earlier iOS-main audit | ~195–198 ms CPU/s remained outside measured UIKit phase windows | — | A measurement residual, **not** attribution to one function, UIKit, CPU core, frequency, or VM |
| Earlier fixed main computation | ~2.1x slower in one in-JAR Treo state | — | Possible scheduling / clock / core difference; not demonstrated cause |

A/B/A raster runs and GameCanvas runs are separate windows. Their CPU values must not be merged into a single causal breakdown. No shared per-JAR logic-tick or direct power meter was available; paintHz alone is not a proof that auto/network works.

## Source-level defects established on the development branch

1. **Expired Java-monitor timeout**: `jvm_util.c::jthread_lock()` supplied `(tv_sec=0, tv_nsec=5ms)` to `mtx_timedlock`. Both C11 and the POSIX implementation expect an **absolute** UTC deadline. Contended monitors thus timed out immediately and repeatedly called `yield()`. Fixed in `aa1f46d` by recomputing `TIME_UTC + 5ms` on each retry and retaining the periodic GC safepoint. Independent Linux pthread repro with 200 ms hold: 13,519 retry attempts/200.06 ms waiter CPU before, 39 retries/0.74 ms CPU after. **Synthetic Linux test, not an iPhone energy or app benchmark.**
2. **Unnecessary bytecode debugger poll**: `interpreter.c` called `jdwp_client_count()` on every interpreted bytecode even when `jvm_bridge_init` configures `jdwp_enable=0`. Fixed in `bee1c65`: only poll when JDWP is enabled. This affects the VM interpreter path, not iOS UIKit main directly.
3. **Default JIT path is off**: `jit.c` has a zero-initialized `treo_jit_enabled` flag, and the ordinary game startup does not turn it on. The normal path therefore interprets Java bytecodes unless a separate supported JIT activation occurs. Do not enable dynamic executable memory unconditionally on iOS; entitlement/runtime availability must be validated.
4. **Runtime frame creation is already pooled** via `runtime_create_inl` / `runtime_destroy_inl`; do **not** repeat a speculative allocation-caching project for each Java call.
5. **Display polling has already been tested** with GC-safe conditional wait; earlier CPU benchmarks did not show a clear whole-app win. Do not make more polling menus without new evidence.

## Research direction (not yet implemented or proven)

**Primary architecture**: a code-signed, no-dynamic-JIT fast interpreter: evaluate direct-threaded opcode dispatch (computed goto under Clang) or carefully verified quickened bytecode operations, while retaining original exception, GC safepoint, stack, debugger, and class-loading behavior. This is a global emulator improvement, unlike hidden-frame suppression. First establish an interpreter-only benchmark on multiple untouched JARs, including synchronized contention and game/auto/network correctness. Every shortcut must have an explicit fallback.

**Secondary, separate issue**: if the iOS main thread remains at 27–35% after VM fixes, obtain an actual *symbolized* main-thread sample with Instruments Time Profiler. A run-loop interval residual or a runnable-PC count cannot identify the guilty function. No more generic UI phase experiments.

**Do not conclude** from CPU% alone that a change reduces heat or energy. Verify real-device behavior, comparable conditions, memory pressure, gameplay, and a longer power/thermal window before enabling any new optimization by default.

Status when written: source fixes pushed; iPhone build and battery impact of these two fixes still unverified. The last user-confirmed working build preceded them.

## Ninja four-state Treo evidence and bytecode audit — 2026-11-21

**New user observation:** At comparable stages of Ninja, CPU is ~40% normally, ~35% with JarBox Treo only, ~20% with the in-JAR Java Treo only, and fluctuates ~10–20% (~15.6% in app log) with both enabled. The main-thread CPU in the latter condition is 0.0% (rounded). Avatar separately reports ~20% normal and 1–3% with Treo **at login before signing in**; this cannot be used as an apples-to-apples active-game Ninja comparison.

**Independent `pymobiledevice3` log:** 876 valid timestamped JSON CPU samples over 461.959 s, collected for one JarBox PID. Selected stable wall-clock offsets measured from the first sample (the log itself has no event-marker timestamps, so segment labels are *inferred* from the owner's account):

| Offset (s) | Samples | Mean CPU | Median CPU | Observed regime |
| --- | ---: | ---: | ---: | --- |
| 180–250 | 132 | 40.07% | 40.60% | high |
| 260–300 | 76 | 33.46% | 33.85% | moderate |
| 310–330 | 38 | 40.52% | 40.65% | another high interval (mode change) |
| 340–380 | 76 | 19.05% | 18.20% | low |
| 392–435 | 82 | 15.27% | 14.64% | very low |

There is a similar first 40% interval at offsets 30–80 s (95 samples, mean 39.64%) followed by 110–150 s at 14.83% (76 samples), plus a later return to ~40%. Do not average all 462 seconds and call it "Treo CPU": the recording contains several modes and loading/transitions.

**Bytecode verified from the immutable uploaded `Nick-B25-Map37-Farm-Clean-CPU.jar`:**

- `NickCpuSleep.requestFrame(Class_hef)` returns without `repaint()` if `NickCpuSleep.active`.
- `NickCpuSleep.flushFrame(Class_hef)` returns without `serviceRepaints()` if active.
- `Class_hef.paint(Graphics)` calls `NickCpuSleep.paint(Class_bs,Graphics)`; when active that method **does not invoke** `Class_bs.a(Graphics)`, the original game paint. Instead it draws only a simple Treo screen if called. Java Treo therefore suppresses the Java rendering *call tree*, not merely final raster.
- `Class_hxb.run()` still runs game-update calls and checks before invoking `NickCpuSleep.requestFrame` then `flushFrame`; it retains the original `Thread.sleep` timing branch.
- `Class_hxb.a(Graphics)` — the original paint path — invokes `Class_hlc.k()`, writes `Class_hvi.a:Graphics` (`putfield`) and calls multiple game rendering helpers. This is **not trivially a pure/side-effect-free method** that a generic emulator can skip with a local Graphics-no-op whitelist.

**Mechanistic synthesis:** JarBox Treo saves about 5 CPU percentage points in both Ninja workload states, while Java Treo saves ~20 points by intentionally bypassing its original paint call graph and frame requests. The earlier JarBox Paint Bridge log reported ~155.41 ms CPU/s inside `paint()` while JarBox Treo was active, corresponding to ~15.54% of one core; this is broadly consistent with a large part of the game-specific Java Treo benefit, but the remaining CPU change, different windows and scheduling cannot be causally allocated without a controlled A/B. The combined ~15% process CPU is the *observed* load of that specific game state, **not** a guaranteed lower bound or a universally required "core engine" rate. Avatar login's 1–3% confirms there is no universal fixed 35% JarBox overhead; its pre-login workload is fundamentally different from an active Ninja game.

**Engineering decision:** Do not add universal `Canvas.paint` suppression or a fixed paintHz throttle: some arbitrary JARs place game state/network activity in or behind `paint`, and Ninja's original paint contains non-Graphics calls and field writes. Retain VM-level Paint Bridge and background lifecycle correctness as already implemented. The next research must be two-pronged:
1. On several untouched JARs, collect *per-paint CPU* and event ingress vs accepted repaint/service counts, plus a low-overhead sampled method call tree **limited to paint**, to identify where time is spent before draws.
2. Investigate **conservative effect analysis** of Java paint helper subtrees. Skip only if virtual targets, native calls, field/array writes, synchronization, exceptions, offscreen pixel dependencies and other externally visible effects can all be proven harmless; otherwise execute normally. Because Ninja's game-specific Treo knowingly bypasses methods with state writes, a sound generic verifier may correctly refuse to skip its whole paint tree. Do not claim the same ~20-point saving is attainable automatically for arbitrary JARs.

**Status:** only evidence and bytecode analysis recorded; **no new performance code was deployed** from this evidence. Preserve the currently working branch.
