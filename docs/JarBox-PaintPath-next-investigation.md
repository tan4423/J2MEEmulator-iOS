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
