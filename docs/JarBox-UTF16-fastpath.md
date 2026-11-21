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
