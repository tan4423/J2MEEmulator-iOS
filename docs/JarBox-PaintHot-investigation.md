# PaintHot: sampled CPU inside Java Canvas.paint

Checkpoint retained: `faaddc859943d52aa1ad040ded3058ba32afa61a` (iPhone-verified springboard animation fix). This commit only adds diagnostic instrumentation for the unresolved CPU budget in Java paint.

## Sampling design

- Scope: JNI `NativeBridge.profilePaintBegin()` / `profilePaintEnd()`, already called around Java `Canvas.paint()`. Active only for AFK mode 8; selects **1 of every 32** paint callbacks. No new timer, no Java tick throttling, no JAR modifications.
- Hook: `execute_method_impl()` entry and sole return; native and Java method calls both included. The scope-management native `profilePaintEnd` is excluded because it ends the sampling interval before method return.
- For each sampled callback: bounded per-VM-thread 384-depth method stack, 256-entry hashed local table; one merge into 512-entry global hashed table under a mutex at the end of that sampled paint. CPU measured with `CLOCK_THREAD_CPUTIME_ID`, with **self** vs **inclusive** cost. No clock call on every opcode. Overflow, lost self CPU and depth excess are reported.
- Method labels are copied while their class is still loaded (during paint), not dereferenced after the game stops. Session epochs reject late merges from earlier Treo sessions. Diagnostics appear automatically as `[JarBoxVM][PaintHot]` (one summary and top 8 lines) when Treo ends, also in "Xem kết quả đo gần nhất".
- Sampling and method timing have a nonzero observer cost. Values are for *sampled* paint callbacks, not total CPU consumed or watts. Inclusive CPU double-counts ancestors; self time should be used for hotspot ranking. Native child calls are separately timed unless they are the scope-management helper.

## Matched overhead test

In Codemagic "J2ME Treo JIT probe unsigned", the default is `paint_sampler=1-in-32`. Set `JARBOX_PAINT_SAMPLE_DISABLED=1` to build a same-HEAD baseline with disabled hooks. Keep `JARBOX_VM_SWITCH_BASELINE=0`, `JARBOX_VM_PAINT_BRIDGE_BASELINE=0`, `JARBOX_BG_ANIM_BASELINE=0` in both. Check CPU app/main, Java paint/s, smart GC, renderer fallback and Java logic. Compare identical game states using `pymobiledevice3`; instrumentation is not a claimed optimization.

## Decision gate

- A useful trace has `sampled > 0`, most sampled CPU accounted for by self methods, and few or zero overflows. If sampling causes significant CPU overhead, disable for production and retain it as an opt-in diagnostic.
- Inspect top exclusive-CPU functions by bytecode/control-flow analysis. Do **not** automatically skip them just because they run beneath paint. Treat field/array writes, synchronization, exceptions, virtual calls, native calls, offscreen pixel dependencies, input/network/game state as side effects until proven otherwise.
- If no Java-only pure helper consumes significant CPU, stop pursuing unsafe whole-paint skipping and optimize engine execution instead.

**Build / iPhone verification status**: not yet tested for this new diagnostic commit.
