# JarBox springboard background animation lifecycle CPU experiment

Commit candidate for the main-thread ~27% CPU problem.

## Source-derived cause candidate

`AppsListViewController` constructs an `AnimatedBackgroundView` with six circles. Each animation's completion used to call `animateCircle` again without a stop condition. A full-screen game controller overlays the springboard, but the original source did not explicitly stop these UIView animations when the springboard disappeared. This can maintain Core Animation activity and main-thread completion callbacks while the app is playing or in Treo.

**Not proven:** iOS may automatically suspend offscreen/removed layers, so actual excess CPU is unknown. Earlier attempts at removing game-controller subviews do not directly test the *presenting springboard*'s animations.

## Candidate

- Suspend and remove animation objects in `AppsListViewController.viewWillDisappear` and immediately when selecting a game; resume when the springboard reappears.
- Cancel recursion by clearing the `animating` state **before** removing circle layer animations and checking `finished` in completion.
- Keep initial circle layout independent from animation state, so Auto Layout cannot restart paused animations.
- No changes to JVM, JARs, game logic, network, GC, the renderer or modes.

## Embedded verification (no new menu)

Game Treo report `[JarBoxVM][Treo]` includes `springboard_motion`, `springboard_layers_at_pause` and `springboard_loops_during_treo`. The extra NSLog `[JarBoxBG]` records transition reasons, number of active animation objects before pause, and completed animation loops.

**Expected candidate:** `springboard_motion=paused`, `springboard_loops_during_treo=0`. The paused layer count is only a snapshot, not a measure of CPU. Main CPU and process CPU must be compared by `pymobiledevice3` under equal device conditions.

**Baseline build from the same HEAD:** In Codemagic `J2ME Treo JIT probe unsigned` set `JARBOX_BG_ANIM_BASELINE=1`; the springboard controller retains the old behavior and logs `[JarBoxBG] baseline retained`. Keep `JARBOX_VM_SWITCH_BASELINE=0` and `JARBOX_VM_PAINT_BRIDGE_BASELINE=0` for both candidate and baseline. Build output shows `[JarBoxBG][BUILD] springboard-animation=baseline-keep` or `pause-when-hidden`.

**Success condition:** reliably lower app **main-thread CPU** across comparable runs without changing Java paint cadence, GC, game state, UI restoration or auto/network. The main thread previously used ~26.9% and VM paint ~162 ms/s; the main thread is distinct from the VM. A lack of measurable main CPU difference means the animations were not material; keep lifecycle cleanup only as justified by code correctness.

**Status:** source patch staged for on-device verification. No claims of a successful iOS build, battery or CPU improvement.


## First real-device result — candidate enabled (user observation)

**Build:** default `springboard-animation=pause-when-hidden`, VM computed-goto and Paint Bridge on. Exact IPA SHA / JAR name / clock times of AFK start/end not provided. **Status: strong corroborating evidence; not yet a same-HEAD animation-on A/B.**

| Metric | Earlier Paint Bridge, springboard not explicitly paused | This candidate |
| --- | ---: | ---: |
| Treo duration | 158.7 s | 130.5 s |
| Process CPU time normalized / wall time | 57.1% | **30.2%** |
| Main-thread CPU time normalized / wall time | 26.9% | **0.0%** (rounded to 0.1%) |
| Java `paint()` calls/s | 25.62 | 25.54 |
| Java `paint()` CPU ms/s | 162.40 | 155.41 |
| GC CPU ms/s | 12.34 | 11.64 |
| Smart GC cycles | 91 | 72 |
| Collector heap peak (Java+GC-counted native) | 22.2 MiB | 16.3 MiB |
| Guarded Canvas raster skips | 4,065 | 3,333 |
| Pixel fallback | none | none |
| VM draw calls elided by Paint Bridge | 3,964,040 | 3,473,836 |
| Computed-goto interpreted methods (approx.) | 38,437,504 | 34,040,704 |
| Springboard animation state | not instrumented | `paused` |
| Active springboard animation layer keys before pause | not instrumented | 18 |
| Completed animation loops during Treo | not instrumented | 0 |

The numerical difference in **whole-process CPU** is **-26.9 percentage points** (57.1 -> 30.2) and **main CPU** is also **-26.9 points** (26.9 -> 0.0). Meanwhile Java paint rate is similar. This is *consistent* with eliminating a main-thread load source external to the game renderer, but two sessions of different durations without matched conditions cannot establish causation or energy savings. Source-review confirms the main-thread counter comes from `CLOCK_THREAD_CPUTIME_ID`; process CPU comes from `getrusage(RUSAGE_SELF)`.

### Independent pymobiledevice3 attachment

A separate user-supplied text log reports 312 parseable JSON process CPU samples over 164.505 s (one final truncated JSON line). Whole-file arithmetic mean: **31.54%**; median: **35.31%**. These are sampled instantaneous process CPU percentages and **not** aligned exactly to the 130.5-s AFK window. The data show materially different regimes:

- +10–30 s from start: around 39–41% CPU
- +50–90 s: mostly 18–23% CPU
- +100–150 s: mostly 35–39% CPU

Thus even after main CPU is eliminated the Java/game workload varies. Memory physFootprint near the end is about **69.3 MiB** (total app footprint), which must not be equated with the **16.3 MiB** GC-counted peak (different definitions).

### Decision / next discriminating verification

1. Keep lifecycle cleanup on the development branch as a quality improvement.
2. Use **one matched same-HEAD counterfactual**: build with `JARBOX_BG_ANIM_BASELINE=1` (only switch animation lifecycle back); keep `JARBOX_VM_SWITCH_BASELINE=0`, `JARBOX_VM_PAINT_BRIDGE_BASELINE=0`. Compare the **same untouched JAR**, similar game state and brightness, and confirm `springboard_motion=running`, `springboard_loops_during_treo`, `main_CPU`, `app_CPU`, paint/s and `pymobiledevice3`. If the baseline reproduces ~27% main CPU, the source hypothesis becomes strong evidence rather than inference.
3. If matched CPU improves, then optimize *separately* the remaining Java paint CPU (~155 ms/s) and game loop. Do not skip entire `paint()` or modify JARs: some logic depends on it.
4. Real game logic, network/auto and visual restoration must be tested; neither paint cadence nor no-fallback counts prove these functions.
