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
