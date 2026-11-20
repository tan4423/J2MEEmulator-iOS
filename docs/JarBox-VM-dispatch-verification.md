# JarBox VM direct-dispatch verification

Branch: `loader-ios-jit-probe`. The game JARs are untouched. **No savings are established until on-device comparison.**

## What changed

- `interpreter.c`: iOS Clang uses code-signed, direct-threaded dispatch to 230 existing opcode handlers. The original `switch` remains available; Java semantics, exception handlers, JDWP checks and GC checks are not removed.
- `jvm_util.c`: count *actual* monitor contention and failed acquisition retries, not every uncontended lock.
- `GameViewController.swift`: automatically log one `[JarBoxVM][Treo]` line upon leaving Treo. It also appends the same line to **Xem kết quả đo gần nhất**. No new menu or repeated test is required.
- All Java-method counters are batched in groups of 64 *per VM thread*, so values marked `~` are approximate. They are not counts of individual bytecodes.

## Matched builds from one Git HEAD

In the Codemagic workflow **J2ME Treo JIT probe unsigned**:

1. Candidate: leave `JARBOX_VM_SWITCH_BASELINE` unset or set to `0`. The build log says `[JarBoxVM][BUILD] dispatch=computed-goto`.
2. Reference: set Codemagic environment variable `JARBOX_VM_SWITCH_BASELINE=1`. Build log says `[JarBoxVM][BUILD] dispatch=switch`.
3. Compare equivalent on-device workloads, game locations, JAR content, Smart GC policy, screen brightness, network, JIT state, device temperature, and measurement durations. Collect `pymobiledevice3` CPU values **and** the JarBox log. Alternate reference/candidate runs where practical.

Both builds use the *same current source*, rather than comparing against months of unrelated source changes. The flag is passed as `-DTREO_VM_FORCE_SWITCH=1` only in the reference build.

## Log and acceptance criteria

Example shape (not a measured result):

```text
[JarBoxVM][Treo] 60.0s · dispatch=computed-goto · direct_methods~112640 · switch_methods~0 · monitor_contended=3 · monitor_failed_acquires=5 · app_CPU=35.0% · main_CPU=20.0% · paint=25.35/s · layer_frames=0 · smart_GC=12. Counts batched/64; paint is not game ticks; CPU is not watts.
```

- Candidate valid: `dispatch=computed-goto`, `direct_methods~ > 0`.
- Reference valid: `dispatch=switch`, `switch_methods~ > 0`, `direct_methods~ = 0`.
- If monitor contention is negligible, the earlier mutex fix was likely not a major workload CPU bottleneck, even though the timeout bug was real.
- Compare **whole-app CPU** and `pymobiledevice3` under matched workloads, not the number of method calls alone. Confirm `paint` cadence, `layer_frames` and Smart GC counts are comparable. `paint` is only a partial workload proxy, not a generic Java/game tick counter. If saving is marginal or inconsistent, **do not promote direct dispatch**. If the app crashes or Java logic/auto/network breaks, return to the user-verified build.
- `main_CPU` is Apple's UI main-thread CPU, not CPU time of the JVM interpreter.
- CPU% is not watts. A high-quality decision requires stable game logic, auto/network, UI restoration, and longer power/thermal observations.

## Structural verification

At source-generation time, the build was checked to contain **exactly 230** distinct top-level opcode cases, all mapped to labels, with the original `switch` and unsupported-opcode fallback retained. A local standalone Clang smoke test checked equivalent behavior for direct/switch paths, grouped cases and unsupported opcodes. That smoke test does **not** constitute compiling JarBox or running a device benchmark.

**Unverified at source-commit time**: Xcode/iOS build, code signing, actual iPhone CPU change and energy impact.


## Real-device candidate observation — user-provided log

Build: computed-goto candidate on this branch (exact installed IPA SHA not supplied).
Workload: Treo sâu with guarded Canvas raster skip and Smart GC, duration **106.5 s**. The JAR filename is not present in the log; do not attribute it to Ninja or Avatar without confirmation.

| Metric | Observed |
| --- | ---: |
| App CPU (single-core equivalents) | 59.6% |
| iOS main CPU | 27.3% |
| Computed-goto interpreted method invocations (approximate, batched/64) | 29,676,992 |
| Switch interpreted method invocations (approximate) | 0 |
| Monitor contentions | 1 |
| Failed monitor acquisitions | 1 |
| Java paints/s | 25.57 |
| Native layer frames | 0 |
| Canvas raster skips | 2,724 |
| Canvas raster preserved | 0 |
| Late dependent pixel reads | 0 |
| Canvas fallback | none |
| Smart GC cycles | 58 |
| Smart GC CPU time | 13.49 ms/s |
| GC heap peak | 25.4 MiB |
| Smart GC fallback | none |

Interpretation:
- **Proven:** the direct-dispatch path was exercised heavily (~278,657 interpreted method calls/s); the old switch had no counted interpreted method invocations in this window. Layer frames and fallback were zero. Game code continued requesting Java paint calls at ~25.57/s; this does not prove game logic/auto/network correctness.
- **Likely not the bottleneck:** contended Java monitors, only one reported contention/retry in the interval.
- **Not proven:** improvement in app CPU, iOS main CPU, watts or battery. Historical deep-Treo measurements near 60% process CPU are not matched switch controls and must not be used as a causal A/B result.
- **Next valid comparison:** build this same source with `JARBOX_VM_SWITCH_BASELINE=1`, verify `dispatch=switch` and `switch_methods~ > 0`, then compare with `pymobiledevice3` plus the same JarBox VM fields for a similar duration, location and operating conditions. Confirm paint rate, GC count, layer frames, fallback, auto, network and visual restoration.

This observation came from the device owner and is preserved verbatim in substance; it was not independently re-measured by this development session. No new code change was made in recording it.


## Paint bridge (mode 8) — second, independent optimization candidate

**Source change:** retain the JAR's Java `Canvas.paint()` callbacks (state, game logic, timers, input/network remain under normal VM semantics); for a verified bundled `javax.microedition.lcdui.Graphics` instance drawing into an actual headless Canvas, the VM can omit only draw-wrapper methods whose bodies are guaranteed to return without doing work while headless. This reuses the preexisting mode-4 method whitelist and `treo_afk_elide_graphics` checks (exact class, layout, Canvas native-context pointer, thread-local active Canvas, headless field, Java method signature and ABI marker). Mode 8 now uses the same narrow bridge. **Graphics state-mutating methods, getters, pixel-dependent paths, offscreen Image graphics, unknown implementations, Java game methods, and all other calls are preserved.**

**Matched candidate vs baseline from the same HEAD, still with `computed-goto`:**
- Default: `JARBOX_VM_PAINT_BRIDGE_BASELINE` unset/0; Codemagic build log: `paint_bridge=on`; device VM log: `paint_bridge=on`, `bridge_elided_draw_calls` should increase when the Canvas has verified draws.
- Baseline: `JARBOX_VM_PAINT_BRIDGE_BASELINE=1`; Codemagic build log: `paint_bridge=off`; device log: `paint_bridge=off`, `bridge_elided_draw_calls=0` for mode 8. Mode 4's experimental behavior is intentionally unchanged in both builds.
- Keep `JARBOX_VM_SWITCH_BASELINE` unset/0 for both paint-bridge builds: changing dispatcher as well would confound the result.
- Device log also reports `paint_CPU` **ms/s of paint callback CPU time**, app CPU %, iOS main CPU %, paint/s, native layer frames, GC cycles, monitor contention, and approximate interpreted-method counts. The VM does **not** add an individual clock read for each elided draw; it aggregates counters once the paint exits.
- Accept only a stable app CPU/pymobiledevice3 benefit under similar workload, with comparable paint/s and JAR logic/auto/network correctness plus correct screen restoration. If `bridge_elided_draw_calls=0`, the optimization never activated. If it activates but CPU does not improve or compatibility regresses, keep the verified interpreter path and disable/rollback the new bridge.

Important limitation: **no generic emulator can prove that arbitrary game code inside `paint()` is pure drawing**. This implementation never skips the game's paint callback or its helper methods. A later interprocedural purity verifier could skip *proven* graphics-only helper subtrees, but would require proof and fallback rather than heuristics. Treo is not allowed to break networking or game state merely because pixels are hidden.

**Verification status:** source and cross-file instrumentation reviewed. Xcode build and iPhone A/B are pending; do not claim power or thermal savings.
