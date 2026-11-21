# Ninja Deep Treo — phase 1: exact-JAR early presentation bypass

## Direct bytecode evidence from the uploaded Ninja JAR

SHA-256: `7e1cff13508f0c43ad2fee30e75b38d807a1811a21fff8fbbe3ce6f70215f0a1`

The class `NickCpuSleep` gates `Class_hef.repaint()`, `serviceRepaints()`, and `Class_bs.a(Graphics)` within `Class_hef.paint()`. `Class_hxb.run()` runs game-state updates and then requests a frame; it is independently paced with `Thread.sleep`. This is evidence of a useful game/render split, not a requirement to reproduce the original Treo exactly.

## Mode 8 implementation

On `jvm_bridge_init`, compute the actual JAR's SHA-256 using CommonCrypto. Fail closed if unreadable or different. When mode 8 is active and the current Canvas Java type is exactly `Class_hef`, skip `Canvas.repaint()`, `Canvas.serviceRepaints()`, and `Canvas.doPaint()`. This removes the Java paint tree earlier than generic headless Graphics. Preserve the user-configured `limitFps()` in `repaint()`, avoid changing any game tick, network, RMS or offscreen Image logic, and rely on the existing mode-exit full redraw.

A pair of native checks guard each skip against mode changes. The profile is not applied to Avatar, other games or other Ninja JAR variants. No JAR on disk is changed.

The log includes `ninja_profile=matched|generic`, `ninja_repaint_skips`, `ninja_service_skips`, and `ninja_paint_skips` to distinguish early presentation suppression from generic Canvas raster counts. In this candidate, generic `paint` and `Canvas raster skipped` may approach zero because the paint requests have been removed before they reach `doPaint()`.

## Single Codemagic workflow

Only `J2ME Treo JIT probe unsigned` on `loader-ios-jit-probe`. Array Lookup and PaintHot diagnostic flags are OFF for cleaner CPU comparison.

Test the exact Ninja JAR with its own Treo OFF and the same farming scene. Start JarBox mode 8 for 100–180 seconds, exit, and check map/tick progression, live network/auto, saved RMS state, touch, brightness, and screen repaint. Report `[JarBoxVM][NinjaDeep]` and full `[JarBoxVM][Treo]` plus GC/Canvas. A matched profile and positive skipped frame counters demonstrate activation; they do **not** prove CPU/energy savings.

For a same-source baseline, a future commit on this *same* workflow can add `-DTREO_NINJA_DEEP_DISABLED=1` to the compile CFLAGS, without creating any new workflow. If the impact is good, continue by side-effect analysis of deeper map/sprite render-only Java work before any further elision.

**Current status:** GitHub source changes only. No fresh Codemagic IPA or device test completed; feature should not be described as production-ready.
