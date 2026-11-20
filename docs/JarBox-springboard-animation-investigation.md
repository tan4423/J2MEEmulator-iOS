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
