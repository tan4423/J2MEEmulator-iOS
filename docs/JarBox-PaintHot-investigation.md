# PaintHot: sampled CPU inside Java Canvas.paint

Checkpoint retained: `faaddc859943d52aa1ad040ded3058ba32afa61a` (iPhone-verified springboard animation fix). This commit only adds diagnostic instrumentation for the unresolved CPU budget in Java paint.

## Sampling design

- Scope: JNI `NativeBridge.profilePaintBegin()` / `profilePaintEnd()`, already called around Java `Canvas.paint()`. Active only for AFK mode 8; selects **1 of every 32** paint callbacks. No new timer, no Java tick throttling, no JAR modifications.
- Hook: `execute_method_impl()` entry and sole return; native and Java method calls both included. The scope-management native `profilePaintEnd` is excluded because it ends the sampling interval before method return.
- For each sampled callback: bounded per-VM-thread 384-depth method stack, 256-entry hashed local table; one merge into 512-entry global hashed table under a mutex at the end of that sampled paint. CPU measured with `CLOCK_THREAD_CPUTIME_ID`, with **self** vs **inclusive** cost. No clock call on every opcode. Overflow, lost self CPU and depth excess are reported.
- Method labels are copied at each sampled VM method return, while that method's frame is still live. The end-of-paint merge copies the owned strings without dereferencing stored MethodInfo pointers. The bounded TLS tables increase memory usage in diagnostic builds; disable sampling for a production baseline if not needed. Session epochs reject late merges from earlier Treo sessions. Diagnostics appear automatically as `[JarBoxVM][PaintHot]` (one summary and top 8 lines) when Treo ends, also in "Xem kết quả đo gần nhất".
- Sampling and method timing have a nonzero observer cost. Values are for *sampled* paint callbacks, not total CPU consumed or watts. Inclusive CPU double-counts ancestors; self time should be used for hotspot ranking. Native child calls are separately timed unless they are the scope-management helper.

## Matched overhead test

In Codemagic "J2ME Treo JIT probe unsigned", the default is `paint_sampler=1-in-32`. Set `JARBOX_PAINT_SAMPLE_DISABLED=1` to build a same-HEAD baseline with disabled hooks. Keep `JARBOX_VM_SWITCH_BASELINE=0`, `JARBOX_VM_PAINT_BRIDGE_BASELINE=0`, `JARBOX_BG_ANIM_BASELINE=0` in both. Check CPU app/main, Java paint/s, smart GC, renderer fallback and Java logic. Compare identical game states using `pymobiledevice3`; instrumentation is not a claimed optimization.

## Decision gate

- A useful trace has `sampled > 0`, most sampled CPU accounted for by self methods, and few or zero overflows. If sampling causes significant CPU overhead, disable for production and retain it as an opt-in diagnostic.
- Inspect top exclusive-CPU functions by bytecode/control-flow analysis. Do **not** automatically skip them just because they run beneath paint. Treat field/array writes, synchronization, exceptions, virtual calls, native calls, offscreen pixel dependencies, input/network/game state as side effects until proven otherwise.
- If no Java-only pure helper consumes significant CPU, stop pursuing unsafe whole-paint skipping and optimize engine execution instead.

**Build / iPhone verification status**: not yet tested for this new diagnostic commit.


## Device sample (68.5 s) and observer-bias diagnosis

User reports 39.5% process CPU, 0.1% main CPU, 372.24 ms/s paint CPU, 25.42 paint/s, 1741 paints with 55 selected samples. Top methods by sampled self CPU are ByteArrayOutputStream.write (258.40 ms), UTF_8_Writer.write (191.41 ms), Character.isHighSurrogate (152.79 ms), InnerFile.loadFS (108.93 ms), System.arraycopy (93.86 ms), UTF_8_Writer.sizeOf (86.52 ms), ByteArrayOutputStream.ensureOpen (78.79 ms) and String.charAt (45.62 ms). These are real Java/data/OS-file operations, **not safe draw no-ops**. Native InnerFile.loadFS calls stat() and updates metadata; native System.arraycopy uses memmove(). Do not skip them blindly.

Selected paint CPU ~1882.86/55 = **34.23 ms/paint** versus total paint CPU ~372.24/25.42 = **14.64 ms/paint**. Source-level profiler clocks every sampled method entry/exit, so self-time includes profiler overhead. Sampled method rankings cannot yet be interpreted as unbiased uninstrumented CPU hotspots; variance or periodic selection bias may also contribute. Bridge-elided calls ~120/paint (208920/1741) differ markedly from earlier log ~1040/paint, so the game scene/JAR may differ. No matching workload conditions supplied.

Added same-run observer comparison: `sampled_paint_avg` versus `plain_paint_avg`, with counts and `observer_ratio`, using timestamps ALREADY obtained by NativeBridge.profilePaintBegin/End. No extra clock or timers. This distinguishes measurement cost / selection skew from all-paint averages, but remains observational; a same-HEAD `JARBOX_PAINT_SAMPLE_DISABLED=1` build is the clean overhead control. Aim to preserve the CPU-main fix. Do not optimize character encoding, filesystem metadata, array copying or game loop before validating the denominator and semantic use.


## Call-site investigation after 87.4-s PaintHot log

The follow-up user log has process CPU 39.0%, main CPU 0.0%, Java paint CPU 369.22 ms/s, and 25.44 paints/s. A **same-session comparison** shows selected paints average 32.90 ms (n=70) versus unselected paints 13.91 ms (n=2155), observer ratio 2.36×. The apparent extra CPU is (32.90 - 13.91) × 70 / 87.4 = **15.21 ms/s**, ~1.52 process CPU percentage points, **if** selected and unselected paints have equal intrinsic work. Thus CPU profiling overhead is significant per selected paint but cannot account for all 39% process CPU. Don't use the self-time ranking to infer uninstrumented proportions.

Independently verified with a complete constant-pool + bytecode call graph of the uploaded `Nick-B25-Map37-Farm-Clean-CPU.jar` (323 classes): `Class_hef.paint` delegates to `NickCpuSleep.paint`, and when Java Treo is disabled it calls original `Class_hxb.a(Graphics)`. The original paint tree reaches 74 JAR methods; it invokes Graphics state and draws, string buffers, and includes a static path `Class_hxb.a -> Class_hwe.a -> Class_hfa.j -> Class_hfa.<init> -> Class_hha.a -> Class_hac.o24 -> Class_hac.<init> -> Class_hxb.q4 -> Image.createImage(String)`. **There is no direct method reference to `ByteArrayOutputStream`, `UTF_8_Writer` or `InnerFile` in these 74 JAR methods**. These classes are part of Java runtime / J2ME library internals (e.g. Image resource loading, file lookup and encoding), not a direct Ninja draw method. Since `Class_hfa.j` creates a singleton only when absent, this static path is **not evidence of a per-frame load**; JAR identity in the user log is not established.

**Next low-overhead provenance:** In the already-selected 1/32 sampled paints, capture up to two representative *live method chains* for each of `ByteArrayOutputStream.write([BII)V`, `UTF_8_Writer.write([CII)V`, and `InnerFile.loadFS(...)`. Use the profiler's existing call stack, no additional CPU clocks or threads, one chain per target per sampled paint; copy class/method names while frames are live. Report as `[JarBoxVM][PaintPath]` lines. This can distinguish resource/path conversion from text/network/other callers without pretending the representative path covers every invocation. Remains diagnostic, not an automatic optimization. User-confirmed animation fix stays untouched.
