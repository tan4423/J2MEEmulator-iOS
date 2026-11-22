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


## JarBox-wide black **Màn hình Treo** overlay and information menus (v1 UI)

The JarBox library's **⋯ → Màn hình Treo** is a separate screen-cover
function, modeled after the previous in-game Treo black HUD. It covers
the entire navigation controller, including the library toolbar; a single
**centered round wake button** returns to the exact existing library.
All other taps are intercepted by an opaque black, non-animated view.

The global HUD displays **total JarBox process CPU**, the iOS battery
percentage, the system's thermal-pressure category (not temperature in
Celsius), Low Power Mode, the count of live JVM tabs (currently 0 or 1),
the name of the one parked game if it exists, and elapsed overlay time.
It does not invent per-game CPU or claim to list independent JVMs not
yet supported by the native runtime.

**Resource management:** A 15-second timer with 3 seconds of tolerance
only exists while this black HUD is visible **and the JarBox scene is in
the foreground**. Its readings use the existing native process-CPU
counter. The timer is invalidated on wake, library view disappearance,
or app/scene deactivation; on reactivation, the sample baseline is
reset rather than showing stale CPU as a fresh interval. Battery
monitoring is restored to its previous system setting when closing.
The ordinary library without this overlay retains its zero-polling
design: no background HUD timer is created for the global menu.

The black overlay is **display-only**. It does not adjust global
screen brightness or start/stop another Treo mode, JVM, timer thread
in Java or network connection. If a game was parked by Back, its own
automatic mode-8 Treo + Smart GC continues throughout this overlay.
If no game is running, the overlay does not create a game session.
Closing it resumes the library, **not** the game; the user explicitly
taps the parked icon or the "Tiếp tục" control to resume gameplay.
Because this is an opaque UI cover rather than a hardware power-off,
display, GPU, and system power savings require device measurements,
not an assumed percentage. iOS system-background suspension rules
are unchanged.

The separate JarBox-wide **⋯ → Thông tin chung** is the extensible
home for general metrics. **Long-press a game icon → Thông tin trò
chơi** shows game metadata (JAR name/size, vendor/version, resolution
and FPS setting) plus session-specific Treo counters if that game
owns the current live JVM. Those counters are read on demand, never
polled continuously. Process CPU, battery and thermal state are
not incorrectly displayed as if they belonged to an individual JAR.

**Test on iPhone:** Park Avatar via Back, open ⋯ → Màn hình Treo,
observe several 15-second samples, wake, verify session still runs,
then resume Avatar without relaunch. Repeat with no running game and
confirm baseline CPU remains close to idle when the cover is closed.
Confirm the cover responds to iPhone scene/background transitions
without restarting its sample timer while inactive.

The new global menu and cover are regular UIKit source changes,
not yet built/tested on an iPhone. The existing one Codemagic workflow
and native singleton ownership safeguards remain unchanged.


## Multi-JVM native isolation — implementation stage 1 (2026-11-22)

The developer requested **independent, truly concurrent Java ME sessions**.
The current source has been modified immediately, but **the runtime is
not yet authorized to start two live JVMs**. Enabling it early would be
a real memory/IO safety regression, not an MVP.

### Shipped source changes

1. \`jvm_bridge.c\` moves the active \`MiniJVM*\`, phase, stop state and
   generation token into a typed \`JarBoxVMContext\`. The JVM owner pointer
   is an atomic C pointer, and Java's native \`isStopRequested\` checks
   **its own** \`runtime->jvm\` instead of blindly taking a global stop flag.
   The existing exclusive acquisition CAS remains enforced.
2. \`j2me_input.c\` now owns up to four **native input contexts**, each
   bound to a concrete \`MiniJVM*\` rather than one process-global ring.
   Java \`pollInputEvent\` and Display-wait JNI resolve the context from
   \`runtime->jvm\`; each has its own condition variable and wake sequence.
   UIKit physical input is routed only to the explicitly focused context.
   Binding fails rather than silently sharing an input ring. A native
   cleanup removes only the ending JVM's ring and condition state.
3. \`jarbox_input_ring.h\` is the **real production** SPSC ring primitive
   with explicit C11 acquire/release ordering. The C host regression
   compiles this exact header and runs **two concurrent producer/consumer
   pairs**, 12,000 events per ring, including independent overflow and
   reset tests. A separate local C smoke test ran 30,000 events per ring.
   Input-context capacity four does **not** imply four working JVMs.
4. Audio now tracks native WAV/MP3 and MIDI handles by their creating
   JVM. Start/stop/close/volume/time methods check ownership. Ordinary
   teardown calls \`j2me_audio_stop_for_vm(owner)\` and does not call the
   old global \`stop_all\`; iOS \`AVAudioSession\` remains a physical
   process-wide service by design. Per-player audio-completion callbacks
   capture the input binding generation and dispatch to the main
   producer queue, preventing an old game's completion from generating
   input in a later game even if its VM address is reused. Immutable
   soundfont and AVAudioSession setup use \`dispatch_once\`.
5. \`tools/multivm_readiness.py\` returns a source-structure report with
   a truthful **false** \`concurrent_jvms_safe_to_enable\` status while
   any global state blocker exists. \`--require-ready\` exits nonzero.
   New tests guard ownership, audio callbacks, exclusive teardown and
   the remaining safety gate. These tests do not replace Xcode/iPhone
   testing of real Java threads.

### Blockers that still prevent real concurrent game execution

| Native subsystem | Shared process state to separate |
| --- | --- |
| 2D renderer and Canvas | \`g_flush_callback\`, image/context handles, UI layer targets |
| MIDP Form/List/Alert | \`g_form_title\`, \`g_ui_callback\`, commands, list contents, pending text, revisions |
| Treo / GC | \`treo_afk_mode\`, Smart GC scheduling, \`g_native_extra_heap\` included in each JVM GC calculation |
| 3D | \`g_render_3d_scale\`, MC3D/M3G GPU buffers and native handle ownership |
| Networking and diagnostics | Java/socket native ownership plus process-wide diagnostic buffers |
| JVM teardown/JIT | Native heap, stale/zombie Java threads, JIT caches, session-scoped resource cleanup |
| UI/session scheduling | Independent GameViewController destinations, CPU budgets, safe focus/audio/background policy |

In particular, \`garbage.c\` currently includes a global
\`g_native_extra_heap\` in GC heap accounting while
\`j2me_render_cleanup\` resets it globally. Starting B while A is
collecting garbage could charge B's allocations to A or zero A's
accounting when B exits. These are real shared-memory concerns.
The current source audit intentionally refuses to assert multi readiness.

### How to run the checks

\`\`\`sh
python3 -m unittest discover -s tools/tests -p 'test_multivm*.py'
python3 tools/multivm_readiness.py --json
# Unsafe until all subsystems are isolated; exits 2 as designed:
python3 tools/multivm_readiness.py --require-ready
\`\`\`

The existing Codemagic workflow's full test discovery automatically
includes the new test modules. There is no new workflow, no change to
\`main\`, no game JAR modifications, no fake network calls and no
new Treo UI variants. The once-confirmed v9 remains the on-device
regression baseline. No IPA build or dual-JVM device run has been
verified for this native implementation stage.

**Shipping criterion for actual multi-JVM:** remove each real native
shared-state blocker and test two live JVMs performing independent
rendering, input, network/auto, RMS writes, audio, Treo, GC, stop,
restart, and repeated foreground/background switches. Preserve the
exclusive guard until that criterion is met.


## Clone group architecture: one icon, independent default tabs

As of 2026-11-22, the group management and storage path have been
implemented in source. See [JarBox clone tabs](JarBox-Clone-Tabs.md) for
user-facing **+ Tab / − Tab** controls, independent RMS/save directories,
independent user settings and per-tab metadata logs.

The **group key** identifies the source JAR binary. It is NOT the JVM
identity. The original tab has a null clone UUID; each additional tab
has a freshly generated, persisted UUID. The launch path passes that
instance UUID through the UIKit controller and worker to the exact
`app.save.root` set on that miniJVM. Session selection checks both
the original JAR path and clone UUID: two tabs sharing a JAR are never
treated as the same running JVM session.

**Default clone semantics:** `+ Tab` shares the JAR's code but creates
an **empty save root and fresh default settings**. It never copies RMS,
password/account, settings values, log or RAM state from Tab gốc.
`− Tab` deletes only the selected clone's private save/log/settings
after shutdown, with an explicit confirmation and rollback handling.

This grouping layer does **not** bypass the one-active-miniJVM native
guard. The 2+ JVM goal still depends on per-instance renderer, MIDP
UI, Treo/GC, 3D and network/IO callback isolation. The group abstraction
allows future sessions to be independent from the start without
reworking save paths or user-facing organization.


## Reference: legacy class-duplicated three-tab loader

The uploaded legacy reference `Nicknsonet_t5_x3.jar` demonstrates
a *single-VM, class-repackaged* three-instance MIDlet launcher with
297 original classes plus matching `b/` and `c/` copies. The proven
parts worth keeping are lazy tab initialization, returning to a stored
per-tab MIDP Displayable, closing one tab without closing others, and
clear grouped tab selection. The legacy RMS `a/b/c` store-name prefixes
and its shared `lib.Display.d` / `lib.Connector.UrlMap` Java statics
are **not** full isolation and must **not** replace JarBox's per-clone
UUID save roots or per-JVM native owners.

See [the complete static analysis](JarBox-Legacy-Three-Tab-Loader-Analysis.md)
and its concrete concurrent-session acceptance tests. Reference JAR
contents are not checked into this repository. Two independently safe
JVMs are still not enabled.


## Multi-JVM native separation — follow-on implementation

The native branch now isolates MIDP Form/List/Alert **screen data**
per `MiniJVM*` using reserved `JarBoxUIScreenContext` slots. A
stale Java thread with an unregistered owner is sent to an empty
context, never to another session's visible Form. Each UI context
owns text staging, list icons, commands and revision; when focus
changes the latest owning screen action can be reissued. UIKit's
physical presentation callback is still shared and must be separately
assigned to each `GameViewController` before concurrent execution.

CoreGraphics `RenderContext` and `RenderImage` now carry a native
heap-accounting generation key captured from their creating JVM.
The shared `g_native_extra_heap` counter was replaced by a
generation-keyed eight-slot ledger in `garbage.c`. The collector
queries only the active JVM's native allocation total. Late resource
release from an old session cannot debit the replacement JVM after
a pointer address is reused. The ledger is reserved at JVM startup
and unregistered after native renderer teardown; failed startup paths
release their own reservation. The ordinary Java heap/classloader
remains per JVM as before.

New test files `test_multivm_ui_isolation.py` and
`test_multivm_native_heap_ledger.py` guard these contracts.
The latter compiles the **actual ledger C functions** extracted from
`garbage.c` and stresses two independent owners and a recycled owner
pointer. These are host checks, **not** iOS dual-game benchmarks.

**Outstanding before real multi-JVM can be activated:** render
framebuffer ownership, global `g_render_stopped`, `g_flush_callback`
and render resource cleanup; UIKit controller routing; per-VM
Deep Treo and GC scheduling controls; 3D native contexts, socket and
callback ownership; isolated shutdown/restart and on-device
thread-sanitizer/stress tests. `jvm_bridge_supported_concurrent_sessions()`
continues to return **1** and the native exclusive acquisition
CAS remains in place. Do not present this source stage as functional
2+ game execution until these items are implemented and verified.


## Multi-JVM 2D render cleanup checkpoint (2026-11-22)

The single-JVM safety gate is **still on**. This checkpoint splits the *native
2D handle teardown*, not the entire renderer or simultaneous miniJVM execution.

- `RenderContext` and `RenderImage` still carry their native-heap generation
  key. `jvm_bridge_destroy` captures that key before `jvm_destroy` and passes
  it to `j2me_render_cleanup_for_owner` before unregistering the heap ledger.
  The cleanup function removes only that generation's live handles; it does
  not zero the process-wide registry or discard another owner's frame buffers.
- Each handle is detached while the tracking lock is held, but its Treo cache
  and CoreGraphics resources are released **after** unlocking. Cache disposal
  may release tracked images and must not recursively lock the registry.
- Unscoped cleanup deliberately fails closed instead of guessing the owner
  from the currently visible tab. The bridge uses the scoped API.
- Bitmap creation now checks the live owner generation, allocations and decoded
  image dimensions before constructing native handles. The shared immutable
  `CGColorSpace` is initialized with `dispatch_once`.
- Haptic requests capture the creating VM generation and re-check it on
  UIKit's main queue; stale requests cannot replace a newer Tab's player.
  Release callbacks only cancel a player if its generation still matches.
  The haptic engine itself is still shared and is not multi-JVM-complete.
- Forced dead-shell queue drains only occur while the single-JVM safety gate
  is active; otherwise shared queues retain their normal two-generation
  reclamation grace period. The shared stop flag is atomic but not yet
  per-VM.
- Native flush re-checks the visible generation after snapshot construction;
  a frame captured while focus switches is released rather than queued.
  UIKit still independently checks ownership when the queued frame arrives.
- `tools/tests/test_multivm_render_cleanup.py` compiles the actual owner
  extraction helpers into a host C harness. It exercises concurrent owner
  A/B extraction and verifies owner C survives, and source-checks bridge
  ordering and native frame ownership. A standalone sanitizer-host harness
  of these helpers passed ASan/UBSan on Linux. These are **not iOS build or
  simultaneous miniJVM tests**.

**Still blocking concurrent JVMs:** `g_render_stopped` is a shared stop
barrier; native graphics acquire/release, Metal workspace/texture cache, Treo
and Smart GC, UIKit destination ownership, haptics, 3D, sockets and final
VM/thread shutdown still need independent per-generation resource ownership
and on-device verification. Neither the multi-JVM readiness gate nor the
Codemagic workflow has been unlocked.


## MIDP UI generation and native icon ownership checkpoint (2026-11-22)

This checkpoint extends generation isolation beyond render/frame publication.
It **does not** enable two simultaneously running miniJVMs.

- A Java MIDP native call binds both its context slot and the current native
  heap generation, using `g_ui_thread_key`. The slot's generation is atomic,
  invalidated on release, and checked before a Java thread can resolve a
  Form/List/Alert buffer. A recycled slot number alone is not authority.
  This does not prove that a zombie Java thread whose `MiniJVM *` address
  has been recycled cannot rebind: full JVM/thread retirement and session
  lifetime tokens must be validated before enabling parallel sessions.
- UIKit actions are emitted only when the originating JVM generation matches
  both the currently focused MIDP UI context and the visible render owner.
  Swift also checks the **focused MIDP generation** alongside render ownership
  before and after locking screen data, then verifies its revision. A queued
  event is discarded when either destination has switched Tabs.
- `platformRequest` copies the Java URL text before freeing its buffer, then
  checks the captured owner generation again **inside** its main-queue block.
  A request queued by a parked/replaced session cannot unexpectedly open
  Safari for the newly selected Tab.
- The MIDP List-icon path now calls
  `j2me_render_copy_image_for_vm(handle, runtime->jvm)`. This uncommon path
  validates a candidate handle against the live image registry, checks its
  creating generation and increments the refcount while the registry is
  locked. A stale/foreign pointer is rejected before dereferencing it.
  Ordinary hot-path 2D drawing handles **still** use a less isolated raw
  acquisition path and remain a concurrency blocker.
- The new `jarbox_ui_generation.h` policy is tested by
  `tools/tests/test_multivm_ui_generation.py`; a separate compiled C harness
  in `tools/tests/test_multivm_icon_handles.py` extracts the real image
  lookup. Matching host reproductions of these policies passed pthread
  stress with UBSan in this coding session. Full repository test discovery,
  Codemagic build and iPhone stress testing have not been executed here.

Remaining runtime work includes UIKit per-session controller destinations,
all 2D hot-path handle acquisition, scoped renderer stop/Metal caches, Treo
and Smart GC, 3D, callback/socket teardown and the true multi-VM registry.
The existing one-live-JVM guard remains mandatory.
