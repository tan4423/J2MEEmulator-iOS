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
  Long-pressing the icon exposes **Tiếp tục** and **Dừng hẳn**.
- Tapping a different JAR while this JVM is live explains the single-slot
  safety limit and offers stop/resume. The JAR is **not launched** until
  the previous JVM has genuinely terminated and released its resources.
- When the game ends on its own while parked, the overlay library closes,
  the owner controller dismisses, and the ordinary library becomes visible.
- The game's render target is detached and its pending frame discarded
  while the library is displayed. The tested *compatibility* AFK display
  suppression (mode 1) is engaged, then reversed on resume.
  There are no new timers, polling loops, JAR modifications, network
  overrides or CPU/GPU benchmarks in this feature.

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

AFK display suppression is **not** equivalent to suspending or sleeping
the Java game loop: Java logic and its network work continue, so heavily
polling JARs may still use significant CPU. Compatibility is preferred
over globally slowing Java timers, faking network responses or delaying
game logic. Deep Treo stays opt-in, as in the stable baseline; no custom
JAR family heuristics are introduced in the parked path.

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
