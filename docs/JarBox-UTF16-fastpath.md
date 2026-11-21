# JarBox UTF-16 method fastpath — experimental, not yet measured

Stable iPhone-confirmed animation checkpoint: `faaddc859943d52aa1ad040ded3058ba32afa61a`. No animation, network, game logic or JAR modification.

## Rationale
PaintHot showed 144,060 `java/lang/Character.isHighSurrogate(C)Z` calls in 70 selected paints (about 2,058 calls per paint). Its self CPU is inflated by sampled-method instrumentation: sampled paints averaged 32.90 ms vs 13.91 ms without sampling (not causal proof). Optimize method dispatch for a **pure library predicate**, not arbitrary paint or resource-loading logic.

## Semantics
Only an initialized bootstrap `java/lang/Character.isHighSurrogate(C)Z` with one char argument, one boolean return slot, static, nonnative, nonsynchronized, bytecode present, no breakpoint, debugger disabled, thread active and not suspended. Preserve caller-evaluated args; consume one slot and push 0 or 1 according to `(char)value` in range `0xD800..0xDBFF`. Reject user classloader implementations; lazily cache method identity once and batch call counts per 64. This returns the same boolean for every UTF-16 char value; verified by a standalone compiled C exhaustive 65,536-input test. This does not verify whole-app behavior.

## iPhone A/B
Default Codemagic `J2ME Treo JIT probe unsigned`: intrinsic ON. Set `JARBOX_VM_UTF16_BASELINE=1` for an identical-source intrinsic-OFF comparison. `[JarBoxVM][Treo]` reports `utf16_fast=on/off` and `utf16_fast_calls~N` (rounded/batched). For performance comparisons, set `JARBOX_PAINT_SAMPLE_DISABLED=1` in both builds because PaintHot noticeably distorts sampled paint CPU. Keep computed goto, Paint Bridge, animation pause and JAR / scene / timing conditions identical. Compare process CPU, main CPU, paint CPU, GC, game logic/auto/network and restoration. Prefer a short ON/OFF/ON experiment and reject if the effect is noise or regression.

## Status
Source integrated; Xcode/iPhone build and CPU benefit **not yet verified**. Optimizing Character predicate is a candidate for a modest gain; it does not promise 10–20 CPU-point reductions.


## Zero-manual-configuration Codemagic workflows

As of the following CI-ready commit, the builder has two **preconfigured workflows** (same shared script, same source, same bundled JARs):

| Select in Codemagic | UTF-16 intrinsic | PaintHot profiler | Animation pause | Other VM settings |
| --- | --- | --- | --- | --- |
| `J2ME Treo JIT probe unsigned` | **ON** | **OFF** | ON | computed-goto + Paint Bridge |
| `J2ME Treo UTF16 OFF baseline unsigned` | **OFF** | **OFF** | ON | computed-goto + Paint Bridge |

The variables are declared inside `codemagic.yaml`, so **do not manually set environment variables or edit code**. Select branch `loader-ios-jit-probe`, select the candidate workflow, and press **Start new build**. Download the `J2ME-Treo-jar-cpu-audit-unsigned.ipa` artifact from the finished build and install on the existing device using the user's normal unsigned-IPA workflow. For A/B, repeat with the baseline workflow and reinstall its IPA. The two IPA filenames are identical but are in *different build records*: label them with their respective workflow names when saving logs.

Read the build console to verify `paint_sampler=off` and `utf16_fast=on/off` as appropriate; runtime `[JarBoxVM][Treo]` must match. If there is any mismatch, reject that run. Use same original JAR, game scene, state, brightness and similar 90-120-s AFK intervals, with Java in-JAR sleep disabled for isolated JarBox comparison. Record process/main/paint CPU, paint/s, GC, rendering restoration, bot/network status and `utf16_fast_calls~N`. Run candidate -> baseline -> candidate if feasible. Reject changes that don't produce a repeatable improvement or impact game logic.

The known-good animation fix remains untouched, and all changes in this CI-ready commit are workflow defaults and instructions.
