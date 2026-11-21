# JarBox parked games: stage 1 of an isolated multi-session design

Date: 2026-11-21
Branch: `loader-ios-jit-probe`
Baseline: device-confirmed Java 8 v9 / Java 8 functional APIs.
Status: **one live miniJVM, one parked app**, not simultaneous JVMs.

## What works in this stage

- Back in a running game now means **return to the JarBox library**.
  The original `GameViewController` retains the game JVM, threads, network
  connections and Java heap behind a full-screen portrait library.
- The floating menu separately includes **Dừng game hoàn toàn**.
  For portrait and landscape (N-Gage), stop is destructive and triggers the
  existing token-scoped cooperative shutdown, then escalation/recovery only
  if needed. The menu is available over MIDP Forms and Lists too.
- The library shows a static green dot on the live game icon; tapping the
  same icon or **Tiếp tục** returns to the exact existing session.
  **Dừng** is also visible in the library navigation bar. Long-pressing the
  icon exposes **Tiếp tục** and **Dừng hẳn**.
- MIDP game alerts requested while the library is on top are deferred
  until the session is resumed, rather than presenting a second modal from
  the hidden game controller. Later Canvas/Form/List transitions discard
  obsolete deferred alerts.
- Tapping a different JAR while this JVM is live explains the single-slot
  safety limit and offers stop/resume. The JAR is **not launched** until
  the previous JVM has genuinely terminated and released its resources.
- When the game ends on its own while parked, the overlay library closes,
  the owner controller dismisses, and the ordinary library becomes visible.
- A slow stop retains a **Xử lý phiên kẹt** recovery action instead of hiding
  the still-live JVM; importing over the currently running JAR is blocked.
  The parked overlay also rejects new game launches during the narrow native
  teardown → UIKit dismissal window, even if the previous native token is idle.
  The Back control still dismisses a launch-failure screen when no JVM
  was acquired.
- The game's render target is detached and its pending frame discarded
  while the library is displayed. **Going Back into the library automatically
  enables the same existing deep Treo path** used by the formerly separate
  per-game menu choice: native AFK mode 8, guarded Canvas raster suppression
  and Smart GC. The bridge's existing guard automatically falls back to
  compatible mode 1 if a generic game's late-pixel read proves that skipping
  Canvas raster is unsafe. Only a verified NSO Canvas enables the event-driven
  GC-safe Display wait. No per-JAR identification or fabricated game results.
- The user-facing per-game menu no longer contains **Treo tiết kiệm** or
  **Treo tương thích** as separate commands. The one automatic Treo behavior
  is now **Back → library**. The floating menu retains a Back-to-Library
  entry and **Dừng game hoàn toàn**. Existing internal experiments remain
  in source, not in the ordinary user menu.
- Returning to the same game or stopping that game clears the parked
  deep-idle wait, native Canvas guard, Smart GC mode and AFK mode before
  showing a live frame or cooperatively shutting down the JVM. Native
  shutdown after a self-exit clears the state too. No new timers, polling
  loops, JAR modifications, or network overrides are introduced.
- The parked path captures **two passive process-CPU samples only** (when
  entering and leaving the library); a `[JarBoxVM][ParkTreo]` event log
  records elapsed time, average *process* CPU percentage and whether the
  native Canvas guard fell back. These are the same process-wide counters
  available to the prior Treo dashboard and are **not** per-JVM percentages.
  Logging adds no periodic timer or display refresh to the idle library.

## Runtime/OS constraints — intentionally explicit

This is **foreground multitasking inside JarBox**: a game can continue Java
logic while the user browses JarBox's library. iOS normally suspends an app
after it is sent to the iPhone Home screen, except for Apple-approved
background modes. JarBox cannot promise indefinite Java execution in iOS
background or after the process is killed.

The current C bridge contains singleton `g_jvm` and global rendering/input,
audio and graphics state. `jvm_bridge_try_begin_session` exclusively owns
one active token. Running two JVMs by clearing this flag or presenting a
second controller is unsafe and could corrupt the heap, frame callbacks and
resource ownership. The single-session restriction remains intact. This
stage does **not** permit two JARs to execute concurrently, and never claims
to do so.

Deep Treo's Canvas/raster elision is **not** equivalent to suspending or
sleeping the Java game loop: Java logic and its network work continue, so
heavily polling JARs may still use significant CPU. Compatibility is
preferred over globally slowing Java timers, faking network responses or
delaying game logic. The previously implemented native Canvas safety guard
remains enabled while parked. Do not promise under 2% CPU for every JAR:
the user's measured Avatar result (below 2% in its old Treo mode) is a
per-game result, not a fixed budget. The library itself was reported near
0% CPU when no game was running, making the old mode-1 parked game path
the primary suspect for the extra CPU. Benchmark process CPU after 15s of
steady state in library with the same JAR and compare mode-1 baseline,
the original Treo mode and new automatic parked Treo; do not infer accuracy
from screenshots or isolated microbenchmarks.

All activity indicators are derived from the live native session token
and the retained owner controller. No persisted 'running' flag survives
a process restart and no UI claims a dead session is alive.

## Remaining architecture for real concurrent games

1. Audit every native singleton beyond `g_jvm`: Java loader and heap,
   per-game RMS/save root, global Display and Canvas callbacks, `j2me_input`,
   audio mixer, 2D/3D GPU contexts, network native callbacks, timers, GC,
   JIT cache, process-wide power management and shutdown hooks.
2. Introduce per-session contexts and generation-tagged dispatchers, with
   strict memory/CPU budgets, rather than reusing global pointers.
   Launch a second JVM only when its entire heap + native class table +
   callbacks are isolated. Never share a mutable runtime between games.
3. Separately validate pause/resume semantics for networking and game
   clocks; avoid slowing gameplay or breaking game-host synchronization.
4. Add session switcher UI only once actual independent sessions can be
   launched, suspended and stopped safely. Real simultaneous execution
   requires extensive native work and device-based stress testing.
5. Benchmark total CPU/RAM/thermal under 1/2/3 concurrently active games,
   game restart, native crash recovery and iOS scene transitions.

## Testing checklist

- Start NSO, use Back, verify green dot and `Tiếp tục` resumes **the same**
  logged-in character, without relaunching the MIDlet.
- While parked, tap a different icon; must display the one-JVM warning
  rather than launching a second session. Existing JAR remains unmodified.
- Long-press the running icon, choose Dừng; verify the JVM token becomes
  idle, and a different game launches after shutdown.
- Test both portrait and landscape (N-Gage); open the floating menu while
  a MIDP Form/List is showing.
- Compare Avatar **in-game Treo (previous build)** versus **new automatic
  library Treo** under equivalent conditions. Check whether CPU approaches
  its previous below-2% result; no guarantee is made for unverified JARs.
- Confirm that **no manual Treo variant** remains in the portrait or
  landscape floating game menu, and that Back engages mode 8 and Smart GC
  automatically.
- For an unrecognized Canvas, check the guarded fallback to mode 1 when
  late-pixel reads occur, and that resume restores native AFK mode 0.
- Return to the library while a network operation is underway; verify
  socket, sound, timer and rendering behavior on resume.
- Verify iPhone Home/background and app-switching semantics separately.
  **Do not claim indefinite iOS system-background execution.**
- Compare with the device-confirmed v9 baseline: playing FPS, CPU,
  thermal pressure, memory and stop/restart reliability.
- The new `tools/tests/test_parked_game_library.py` source guards run in
  the existing Codemagic test discovery. Only Xcode/iPhone can compile
  and exercise the real UIKit lifecycle; no device verification yet.

No changes were made to `main`, the existing one Codemagic workflow,
Java game JAR files, Deep Treo interpreter optimizations, or the native
JVM singleton ownership rule.
