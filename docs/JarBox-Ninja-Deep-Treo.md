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
