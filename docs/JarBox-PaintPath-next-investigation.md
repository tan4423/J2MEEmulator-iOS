# PaintPath follow-up after cache-no-hit Treo run

## iPhone observations (not guaranteed identical scene)

In a **188.7-s mode-8 Treo** session with the experimental resource cache enabled: `app_CPU=32.2%`, `main_CPU=0.1%`, `paint_CPU=184.27ms/s` (18.427 percentage points), `paint=25.47/s`, `smart_GC=100`, GC CPU 13.82ms/s (1.382 points), `layer_frames=0`, `Canvas fallback=false`, `springboard_loops_during_treo=0`, `thermal_peak=nominal`, `hud_updates=13`. Other work outside paint and GC is roughly 12.39 process CPU percentage points; do not sum overlapping/other subsystem counters without checking definitions.

`image_cache_hits~0` counts batches of 64: it implies **fewer than 64 hit calls counted** in the session, not necessarily literal zero. `image_cache_stores=2`, `image_cache_stored_bytes_total=313`. This does **not** support repeated named-image resource loading as a major process-CPU cause in this session; reject the candidate by default. Heap peak of 23.5 MiB is not directly attributable to these 313 bytes because JAR/scene/state and native heap snapshots may vary. No CPU effect is proven from comparison with older sessions.

## Next question

Previous instrumented `PaintHot` results contained `ByteArrayOutputStream.write([BII)V`, `UTF_8_Writer.write([CII)V` and `InnerFile.loadFS([BLorg/mini/fs/InnerFileStat;)I`. Crucially their ranks were strongly affected by method-level profiling overhead and need accurate caller provenance. They could arise from different resources and game/UI code, not `Image.createImage(String)`. Earlier static call graph did not prove a repeated same-path image load.

`interpreter.c` already has **PaintPath**, a bounded three-target call-stack capture: for each target, up to two representative paths during sampled Canvas.paint calls, 1-in-32 selected paints. Paths contain Java caller names; they are *examples*, not population frequencies. PaintHot's CPU percentages should be ignored as optimization effect due to instrumentation bias.

## Preconfigured build & iPhone test — no code or env edits

1. In Codemagic select branch `loader-ios-jit-probe`, workflow **`J2ME Treo PaintPath diagnostic unsigned`**. Press Start new build. It compiles the current Java/Image+NativeBridge sources and disables the ineffective image resource cache. It enables PaintHot sampling only in this diagnostic IPA.
2. If build succeeds, install its unsigned IPA using the same previous method. Do not accidentally install an older build artifact; check console `paint_sampler=1-in-32`, `image_cache=off (matched baseline)` and HUD/central exit work.
3. Open the same JAR/scene (in-JAR Treo **OFF**). Select JarBox **Treo tiết kiệm**, keep it running **120–180 seconds**. The HUD can show higher CPU than baseline due to profiler overhead: that is expected and **not** a regression conclusion. No need to provoke heat.
4. End Treo via the small centered button. Check original JAR still runs correctly, input/auto/network and screen/brightness restored.
5. Copy **all** the resulting `[JarBoxVM][PaintPath]` lines (ideally six), `[JarBoxVM][PaintHot]` top-method lines, full `[JarBoxVM][Treo]` and GC summary. If no `[PaintPath]` appears, state this explicitly: it implies none of the three targets was captured on the selected paints. This is a diagnostic step to choose the next *actual optimization*, not a performance A/B.

Once caller provenance is known, optimize only safely proven redundant work or faster equivalent runtime primitives; never skip `paint()` or a game-side Java method with possible auto/network/game-state effects. Do not claim a future reduction until a same-source, PaintHot-OFF, matched game-state A/B demonstrates it. The stable springboard pause, center wake and Vietnamese 3-line HUD are retained.

**Build status:** static workflow/source checks only; no Codemagic or fresh iPhone result yet.


## Confirmed PaintPath diagnostic — 2026-11-21 (128.7 s)

The correct instrumented workflow ran: `PaintHot enabled=1 rate=1/32`, 3269 total paints and 103 sampled paints. This is method profiling, **not** a speed comparison. Sampled paint averaged 26.97ms versus plain paint 8.02ms (observer ratio 3.36x). Avoid attributing the observed `app_CPU=36.9%` to a performance regression.

Session: `paint_CPU=218.70ms/s`, `paint=25.38/s`, `main_CPU=0.1%`, 3,143,690 Graphics bridge calls elided, 3268 Canvas raster skips, zero retained rasters, zero late pixel requests / fallback, `smart_GC=68`, GC 14.19ms/s, heap peak 21.1MiB, `layer_frames=0`, `springboard_loops_during_treo=0`, thermal nominal. The 500ms GC interval was restored upon exit. These metrics do not verify game-side progression or battery power.

### Provenance of the three earlier suspicious runtime routines

All captured examples share the RMS path:

`Class_hac.a0 -> Class_hda.a -> Class_hmi.n -> Class_hwh.k -> Class_hsg.f -> RecordStore.openRecordStore -> AndroidRecordStoreManager.openRecordStore -> getDataDir -> File.mkdirs -> File.exists -> FileSystemImpl.getBooleanAttributes -> InnerFile.loadFS`

`String.getBytes -> SocketNative.toCStyle -> FileSystemImpl.getBooleanAttributes` accounts for the `UTF_8_Writer.write` and `ByteArrayOutputStream.write` captures. This means the three PaintPath targets are compatible with **one underlying RMS path**; they must not be treated as three independent proven hotspots. PaintPath examples give neither global frequency nor RMS CPU share.

Source review in `j2me_api/src/javax/microedition/rms/impl/AndroidRecordStoreManager.java` confirms `getDataDir()` builds `root + "/rms"` and invokes `new File(dir).mkdirs()` on each call; `openRecordStore` may call `getDataDir()` more than once. The manager may reopen stores and read headers/records, so it is unsafe to suppress `openRecordStore` or redirect its results. A cache of successful `mkdirs()` calls would also change behavior if the directory is deleted/recreated, or if `app.save.root` changes; such a cache requires explicit invalidation/fallback and controlled A/B. **Do not implement unguarded skipping of RMS I/O.**

### Distinct Java paint work seen in profiler

`Class_hii.k1(LClass_hvi;)V`: 341.92ms self / 103 calls;
`Class_hii.q3(II)I`: 339.49ms self / 156357 calls;
`Class_hui.a(LClass_hvi;Ljava/lang/String;IIILClass_hui;)V`: 242.55ms self / 1444 calls;
`Class_hvi.a(Ljavax/microedition/lcdui/Image;IIIIIIII)V`: 217.44ms self / 92546 calls;
`String.charAt`: 112.45ms self / 39570 calls;
`Class_hjf.elementAt`: 89.65ms self / 26118 calls.

These are sampled, observer-distorted times and cannot be mapped directly onto unsampled process CPU. In particular, the repeated `Class_hii.q3(II)I` calls suggest an interesting *candidate* but require class bytecode inspection to identify semantics before any intrinsic or elision is attempted.

### Next actionable experiment

1. Collect low-overhead counters **per RMS operation**, reporting number of `getDataDir` / `mkdirs` / `openRecordStore` calls and approximate elapsed CPU (when feasible); count result categories (open existing/new, header failures) to preserve correctness. Ensure the instrumentation is actually compiled into the packaged `j2me_api.jar` in Codemagic; the current shared script recompiles only the listed `lcdui` files.
2. Separately inspect the target JAR bytecode of `Class_hii.q3(II)I` and its callers. Do not infer behavior from the obfuscated method name. Favor a pure, semantically identical VM fast path only after inspection.
3. Promote **one** candidate to an ON/OFF same-source Codemagic workflow pair, with PaintHot **disabled** on both. Use matched game scene/time and confirm game network/auto, input, GC, screen wake. Retain only if total CPU improves beyond noise.
4. Keep `main` untouched, image cache OFF, and the proven springboard pause and headless guards intact.

**Status:** diagnostic interpreted and relevant RMS source inspected. No performance optimization, new IPA, or iPhone A/B result is claimed by this document.
