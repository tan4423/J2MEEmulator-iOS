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
