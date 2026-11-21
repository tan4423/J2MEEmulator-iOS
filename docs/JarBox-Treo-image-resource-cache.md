# Treo resource-byte cache experiment — default disabled after device test

> **November 2026 measured outcome:** 188.7 s, app_CPU=32.2%, paint_CPU=184.27 ms/s, image_cache_hits~0 (batched/64, so a few hits are possible), image_cache_stores=2, stored-source bytes=313. There is NO evidence that repeated Image.createImage(String) resource reads are a major cost in this scene. Cache is **OFF in the default JIT workflow** as of the follow-up commit. This document below describes the experimental candidate as originally shipped; see the current workflow matrix near the end.

Branch: `loader-ios-jit-probe` **only**. Never merge into `main` without device A/B, stability and semantics checks. The iPhone-confirmed springboard animation fix remains intact, as do the new centered wake control and 15-second CPU/battery/thermal HUD.

## Motivation and exact scope

The Ninja JAR provided for investigation contains **323 classes and 341 non-class resource entries**, totaling about **675 KiB uncompressed resources**; the resource names include `map/0`, `map/1` etc. The bundled Java `Image.createImage(String)` previously called `findResource`, read a whole classpath stream into `ByteArrayOutputStream`, then decoded a new native image **every time**. A PaintHot session showed heavy ByteArrayOutputStream and UTF-8/runtime filesystem activity, but these samples were costly and **do not prove repeated same-path resource requests**. The runtime test must confirm this hypothesis using cache-hit counters.

This experiment reuses **only the original compressed/encoded resource bytes** of successfully decoded named `Image.createImage(String)` resources. It does **not** cache decoded `Image` objects or native handles: every call still creates its own fresh independent Image and decodes it with the existing native ImageIO implementation. Other `Image.createImage` overloads and direct `InputStream` calls remain unchanged. No game JAR, input, timers, network, bot or Java paint dispatch is altered.

Cache eligibility is checked in native `afkImageCacheEnabled()`: **only if JarBox AFK mode == 8** and the build flag is enabled. Normal gameplay, fallback Treo mode 1, and all offscreen/pixel work continue as before. A cache miss uses the original stream lookup and IOException flow, and only a successful decode can be cached. Key: resource name plus current context ClassLoader identity to avoid cross-classloader mix-ups. The experiment assumes resources in the classpath JAR are immutable while the MIDlet is running; a custom dynamic classloader returning mutable data for the same path could violate that assumption, so compatibility must be tested.

## Memory and observer overhead

Java resource cache is direct-mapped with **128 slots**, at most **256 KiB per entry** and **2 MiB retained source bytes total** (excluding small Java entry/array overhead). Eviction is bounded, synchronized and never touches Java Image handles. Cache hits are counted via one native call for every **64 hits** (rounded down); stores via one native count per successful insertion. `image_cache_stored_bytes_total` is the **sum of bytes inserted during the session**, not live cache memory or number of bytes avoided by reuse. The current version retains the bounded cache for the life of the VM; if this increases GC or heap materially, revert.

Unlike the very expensive method-level PaintHot profiler, this diagnostic uses no per-method clock. It does incur one small mode check on named-image loads in all modes and Java cache-map/synchronization work in mode 8; a CPU speedup is not guaranteed.

## Fully preconfigured matched A/B; zero manual environment changes

In Codemagic select branch `loader-ios-jit-probe`, then choose:

| Workflow | Deep-Treo image resource cache | All other features |
| --- | --- | --- |
| **J2ME Treo JIT probe unsigned** | **ON** | Computed-goto, Paint Bridge, UTF-16 intrinsic ON, PaintHot OFF, animated background pause, center wake, 15-second HUD |
| **J2ME Treo Image Cache OFF baseline unsigned** | **OFF** | Exactly the same flags/source/JAR/appearance as above |

Both workflows run the same shared script, compile the updated bundled Java `Image.java` and `NativeBridge.java` into a *temporary* runtime API JAR during Codemagic build, use a native C compile-time switch and package the unsigned IPA as `J2ME-Treo-jar-cpu-audit-unsigned.ipa`. Each workflow has its own build record even though the artifact filenames are the same.

1. Build the candidate (ON) from this HEAD; verify the build console says `image_cache=on (Treo mode 8 only)` and `paint_sampler=off`. Install its IPA through the same existing unsigned iPhone process. If compilation fails, **do not use an older IPA**, return the full first compiler error so the source can be fixed.
2. Open the exact same original JAR (Ninja or whichever app was measured), same map/screen, disable **in-JAR Treo** and enable JarBox **Treo tiết kiệm**. Keep the app in foreground 150–180 s without touches. At least 15–18 s after activation the HUD should show the 15-second app CPU, battery percentage and iOS thermal **category**. The center round button is the intended touch exit; corners/swipes must do nothing.
3. Touch only the center button, check game view/brightness/auto/network state restore, then copy the full `[JarBoxVM][Treo]` line including `image_cache=on`, `image_cache_hits~`, `image_cache_stores`, `image_cache_stored_bytes_total`, `app_CPU`, `paint_CPU`, `main_CPU`, `smart_GC`, `thermal_peak` and `hud_updates`.
4. Build the **Image Cache OFF baseline** from the SAME HEAD and install its IPA. Repeat the exact JAR/scene/150–180 s process. It must log `image_cache=off`, hits 0, stores 0. Ideally repeat ON after OFF to check natural scene drift (A/B/A).
5. **Keep only with evidence**: positive significant repeated `image_cache_hits`, repeatable overall CPU reduction beyond run-to-run variation, no increased crashes/GC pressure and no game, network or pixel restoration regressions. Reject if hits remain 0 or are too rare to justify caching; if OFF is faster; if heap or GC increases substantially; or if the app loads mutable classpath assets and returns stale bytes. The OFF baseline is the immediate safe fallback without source edits.

Do not confuse GPU or energy with CPU: `app_CPU` is cumulative process CPU time divided by elapsed wall time, not watts, and iOS thermal state is not degrees Celsius. This branch has **source checks only**; no actual Xcode compile or on-device measurement yet.

## Workflow status after field test

- `J2ME Treo JIT probe unsigned`: Image Cache **OFF** by default, PaintHot **OFF**, UTF-16 **ON**, centered wake/HUD retained.
- `J2ME Treo Image Cache ON experimental unsigned`: same as default except Image Cache **ON**. Retained for optional regression investigation only; not recommended.
- `J2ME Treo PaintPath diagnostic unsigned`: Image Cache **OFF**, PaintHot **ON** at 1/32 paints, UTF-16 ON; this produces call provenance at a measurable profiling cost. Do **not** compare its CPU% with normal profiles.
- `J2ME Treo UTF16 OFF baseline unsigned`: same as default except UTF-16 OFF.

No user environment-variable changes are required. In all cases original game JAR is left untouched. The old A/B instructions above are historic; default and former baseline have been reassigned per this field result.
