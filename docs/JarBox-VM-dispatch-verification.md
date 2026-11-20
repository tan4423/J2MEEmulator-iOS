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
