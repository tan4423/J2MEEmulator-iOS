# JarBox — Global state audit for Multi-JVM

Method: scripted scan of file-scope mutable variables (`tools`-less one-off scan of
`J2MEEmulator/minijvm/` and `J2MEEmulator/NativeBridge/`, excluding vendored mbedtls) plus
**real evidence** from `tools/host_multivm_smoke` (two real MiniJVM instances on two
pthreads, headless). Evidence beats regex: rows marked **[TSan]** were observed by
ThreadSanitizer, not guessed.

Legend — scope: P = per-process (shared by every JVM), V = already per-VM.
Risk: **H** can corrupt/steal state between JVMs, **M** logic/behaviour leak or latent race,
**L** diagnostics/counters only.

## A. miniJVM core (`minijvm/jvm`)

| Where | Variable | Scope | Risk | Status / fix |
|---|---|---|---|---|
| `global.c:11`, written in `jvm_util.c:2121-2138` (`init_jni_func_table` from `jvm_init`) | `JniEnv jnienv` | P | **M** **[TSan]** | Every `jvm_init` rewrites the same function-pointer table concurrently (data race by the C model; values are identical, so latent). Fix: one-time init guarded by `pthread_once`. |
| `jvm.c:257-262` | `signal(SIGABRT/FPE/SEGV/TERM/PIPE, …)` | P | M | Handlers are process-wide and installed by *each* JVM; they must stay process-level, not owned per JVM. A JVM-sig handler also hides crash reports. Decide one owner (app), not each `jvm_init`. |
| `jni_std.c`, `jvm.c`, `jvm.h` | `java_lang_Math_random` seed/state | **V** | — | **Fixed in source:** atomic 64-bit state in each `MiniJVM`, seeded during `jvm_create` from time, pointer, and an atomic sequence. Removed process-global `is_random_init` / `srand` / `rand` from Math.random. Non-cryptographic; host full-core/Tsan regression not yet rerun. `java.util.Random` has separate Java implementation. |
| `global.c:367-368` | `pro_lock`, `profile_instructs[]` | P | L | Instruction profiler, off in production. Guard or compile out. |
| `jit.c:124,1287,3516` | `check_suspend` (lazily generated stub) | P | M | Machine-code stub generated on first use. Compiled under `treo_jit_compile_mutex` on iOS, but the plain (non-`TREO_IOS_GAME_JIT`) path in `interpreter.c:1703` uses a per-method lock only. Code does not embed a JVM pointer, so sharing is acceptable once generation is a one-time atomic publish. **Not exercised by host test (JIT stubbed).** |
| `jit.c:24-32` | `treo_jit_*` counters + `treo_jit_compile_mutex` | P | L/M | One global compile mutex serialises JIT across JVMs (performance, not safety). |
| `interpreter.c:24-285` | `treo_vm_*`, `paint_*`, `treo_array_diag_*` | P | L | Profiling counters and a global `paint_global[]` table keyed by `MethodInfo*`. `MethodInfo*` from two JVMs can collide after free/realloc → wrong attribution only. Fix: tag by JVM or disable outside diagnostics. |
| `jvm_util.c:27-29` | `logfile`, `last_flush`, `nano_sec_start_at` | P | M | Log file and start-time shared. `nano_sec_start_at` makes `System.nanoTime()` relative to the first JVM. Make per-VM or document. |
| `jvm_util.c:374-375` | monitor contention counters | P | L | Counters. |
| `jarbox_treo_state.h`, `jvm.h`, `garbage.c` | `JarBoxTreoState` Smart GC and probe metrics | **V** | — | **Fixed in source for GC cadence:** Each MiniJVM owns AFK-mode mirror, Smart GC enabled/fallback, heap/CPU/cycle statistics, and GC probe period/peak/fallback. Collector reads its own JVM; bridge callback pins running session under lifecycle mutex for UIKit control. No concurrent JVM runtime proof yet. |
| `garbage.c:400-402` | `g_native_heaps[]` ledger | V | — | Already per-JVM with generation key (done). |
| `hashset.c`, `hashtable.c` | default-size statics | P | — | Read-only after init (not truly mutable). |
| `ssl_client.c` | `ca_crt_rsa` / `g_ca_bundle_once` | P | M | **Fixed in source:** CA bundle assembled under `pthread_once` and read as immutable thereafter. Full ssl_client/mTLS host and iOS builds not rerun; harness stubs TLS. |

## B. Native bridge (`NativeBridge`)

| Where | Variable | Scope | Risk | Status / fix |
|---|---|---|---|---|
| `jvm_bridge.c:101` | `g_bridge_vm` (single JVM) | P | **H** | The one-JVM limit itself. Replace with a session registry (UUID, generation, state, stop flag, controller). |
| `jvm_bridge.c:20,24`, `treo_*` | `treo_exact_ninja_verified`, `treo_nso_init_target_active`, NSO traces | P | **H** | Treo/NSO state is per-process; one game's Canvas guard can change another's mode. |
| `j2me_render.m:197,289-342` | `treo_afk_mode`, `g_afk_refresh`, `g_afk_needs_redraw`, guarded-AFK flags | P | **H** | Deep-Treo mode is global: parking A would park B. Must move into a per-VM `TreoState`. |
| `j2me_render.m`, `jvm_bridge.c` | 2D stop registry (`g_stopped_render_owners`) | **V by generation** | M | **Fixed in source for 2D lookup:** teardown stops only the identified generation; other owners can still acquire their live 2D handles. The stop table is protected by `g_track_lock` and fails closed if full. Does not isolate shared Metal/3D/Treo or UI callback lifetime; concurrency gate stays 1. |
| `j2me_render.m:167-176` | `g_flush_callback`, `g_visible_render_owner_key`, `g_haptic_player_owner_key` | P | M | Owner-checked now, but single destination. Needs per-VM display destination. |
| `j2me_render.m` | 2D live handles and hash buckets | **V by generation** | M | **Fixed in source for Canvas/Image:** native handle lookups check live registry membership and generation before dereference. Hashed buckets keep the hot drawing path near O(1); destroy is once-only, and owner teardown unlinks both list and buckets. Shared dead-shell drainage and stale zombie pointer address reuse still need on-device validation. |
| `j2me_render.m:1426-1430` | `treo_jar_worker*` | P | **H** | One worker thread/period for all games. |
| `j2me_render.m:2786-3136` | `treo_replay_*`, `treo_live_*` (textures, GPU lock) | P | **H** | Live-Treo GPU texture cache shared. |
| `j2me_ui.m:95-109` | `g_ui_contexts[]` (V), `g_ui_focused_index`, `g_ui_callback` | V/P | M | Contexts are per-VM; callback/focus still single. Needs per-VM UIKit controller. |
| `j2me_input.c:41` | `g_input_contexts[]` | V | — | Per-VM (done). |
| `j2me_micro3d_gl.m:24-30` | `g_mc3d_context/fbo/RB` | P | **H** | One GL context/FBO for Micro3D. |
| `m3g/m3g_egl_ios.m:26-60` | `g_m3g_eagl_context`, surfaces, ctx stack | P | **H** | One EGL context + surface table for M3G. |
| `jvm_bridge.c:364` | `g_render_3d_scale` | P | M | Global 3D scale, per-Tab setting required. |

## C. Evidence from the host smoke test

See `tools/host_multivm_smoke/README.md` for commands and the latest recorded results.
The core interpreter, GC, threads, loopback sockets and file I/O of two miniJVM instances
run side by side in one process. The open items are the table rows marked **H**/**M**
above; none of them is exercised by the host harness (render/UI/audio/3D are stubbed).

## D. Suggested order

1. `jnienv` one-time init, `ca_inited` guard, PRNG per VM (small, safe).
2. Per-VM `TreoState`: GC probe/Smart GC are now instance-owned; migrate Canvas guard, render mode, NSO flags and worker next — highest behavioural risk.
3. **2D render stop and raw handle validation implemented in source.** Remaining: per-Tab presentation callback, Metal/shared-state and full runtime lifetime checks.
4. Micro3D / M3G context ownership.
5. Session registry replacing `g_bridge_vm`; then, and only then, lift the one-JVM cap.

## 2026-11-22 checkpoint: host verification unavailable

- `git am` on a temporary empty checkout failed because original miniJVM source files are not present; the supplied patch was applied as exact Git blobs through GitHub's Git API instead (all eight blob hashes matched the format-patch).
- `tools/host_multivm_smoke/run.sh plain 2`, `asan 17`, and `tsan 3` returned exit code 2 before compilation because this execution environment could not fetch the complete repository. Old TSan logs were cleared first. These commands do **not** revalidate either `jnienv` or the CA/RNG changes.
- The documented 51/51 sanitizer result is user-provided earlier evidence only; the host harness does not exercise UIKit, render, audio, 3D, TLS, or JIT. The single-JVM safety limit remains in place.


## 2026-11-22: NSO server selector / JVM socket transport checkpoint

User observed that the NSO login server selector was blank on iPhone.
The cause is **not yet confirmed on-device**. Two concrete native TCP defects
were found and fixed without changing any JAR, external server address, network
protocol, RMS, login logic or background task cadence:

1. `org_mini_net_SocketNative_available0` returned zero regardless of queued
   bytes; now uses the OS `FIONREAD` query for the **existing** socket.
   This changes no polling schedule and does not consume data. A single
   metadata-only `tcp_first_available` trace is emitted when bytes are seen.
2. Native `KEEPALIVE` and `LINGER` setters/getters incorrectly used
   `SO_RCVTIMEO`. They now use `SO_KEEPALIVE` / `SO_LINGER` and leave
   the receive timeout unchanged. No fake server values or bypasses.

`tools/tests/test_socket_available.py` and
`tools/tests/test_socket_options.py` compile production POSIX helpers
and socket option functions in a loopback/socketpair harness. These tests
cover **OS TCP/socket behavior only**; they cannot prove that NSO's mod server
responded or that the full Java client parsed its response.

**Remaining network ownership:** Each `VmSock` is stored in a VM-owned Java
byte array, but the JNI entry points do not all enforce a native generation
token. Graceful shutdown, outstanding socket I/O, late callbacks, and
TLS per-session teardown must be validated before concurrent miniJVMs.
Keep the single-live-JVM gate. On iPhone, collect `Chẩn đoán kết nối`
from one NSO login attempt, especially `api_stage`, `tcp_connect`,
`tcp_first_available`, `tcp_first_read`, `tcp_first_write`,
`tcp_close`, and `game_net_exception` entries. Empty entries are evidence
too. Do not log credentials, URL or packet bodies.


## 2026-11-22: NSO login server selector and missing RMS logging constructor

Two iPhone diagnostic snapshots, both from IPA
`d5931df2e5a54c2932cec9d1908feb6e4c2f876a`, had different
runtime coverage. The early one showed only startup probes and
`display_poll_count=880`; this did **not** prove that TCP was never called.
The later snapshot showed `display_poll_count=3637`,
`popup_update_count=525`, active game-loop repaint/service/sleep counts,
and successful TCP connect/write/read/close at port 2024.

The actionable repeated exception is:
`mod_method_throw:caller=javax/microedition/rms/impl/RmsEventLog.note,pc=230,op=183,ref=java/io/FileOutputStream.<init>(Ljava/io/File;Z)V`.

**Fixed in source:** `RmsEventLog.note` in the app API JAR previously invoked
`new FileOutputStream(log, true)`, a Java SE constructor missing from
miniJVM's boot `FileOutputStream`. miniJVM exposes the append constructor
`FileOutputStream(String, boolean)`, so use
`new FileOutputStream(log.getPath(), true)`. This keeps the existing
append semantics, per-JVM save root, metadata cap, and non-secret log format.
The existing Codemagic script already recompiles `RmsEventLog.java` into
the shipped `j2me_api.jar`; no workflow/JAR modification is required.

Regression `tools/tests/test_rms_eventlog_boot_compat.py` extracts and
disassembles `java/io/FileOutputStream.class` **from the bundled miniJVM
boot JAR** rather than the host JDK, checks the classfile call signature
from the rebuilt logger, and runs a host-only Java append preservation fixture.
A separate equivalent Java-8-compatible fixture ran successfully on Linux;
full Codemagic, iPhone and full-miniJVM execution **remain unverified**.

This exception affects the emulator's RMS *metadata event logger*, not
necessarily RMS record serialization. It can disrupt an RMS operation if
method resolution fails before the logger's `IOException` handler, but it is
**not yet proved** to be the sole cause of NSO's empty server selector.
Do not rewrite the game JAR, seed fake server entries, modify network
protocols, or enable concurrent JVMs on the strength of this log. Collect
a fresh `JarBoxNET` report from the built IPA if the selector remains empty.

## 2026-11-22: TreoState GC/AFK isolation checkpoint

Changes on `loader-ios-jit-probe` create `JarBoxTreoState` inside every
`MiniJVM` allocation. The collector calls the GC probe/Smart GC operations
on `collector->jvm->treo_state` directly; UIKit controls are synchronous
visitors dispatched only to a RUNNING VM while holding the existing bridge
lifecycle mutex. The AFK mode is mirrored from the existing render setter
into that JVM's GC state; there are no additional timers or polling loops.
Existing Deep Treo modes (including mode 8 and fallback mode 1), the heap
safety threshold, 500/2000 ms GC periods, game packets and save roots remain
unchanged.

`tools/tests/test_multivm_treo_state.py` compiles the actual standalone
policy header into a POSIX pthread harness to verify two independent
session states and fallback isolation. The header model was compiled and
run with ASan+UBSan on Linux in this development session. The bundled
miniJVM, iOS renderer and full Codemagic build were **not** executed locally;
the on-device report that NSO now loads is user-provided validation of
the previous RMS fix, **not** proof of two concurrent miniJVMs.

**Still unsafe for parallel JVMs:** renderer-side
`treo_afk_mode`/`g_afk_refresh`/`g_afk_needs_redraw`, guarded-AFK state,
JAR worker, NSO flags, global render-stop, Metal/3D, UIKit destinations and
shutdown rules. The source gate `jvm_bridge_supported_concurrent_sessions()`
continues to return **1**. Do not change default or Codemagic workflow until
device testing covers those remaining components.

## 2026-11-22: 2D Canvas/Image ownership and scoped stop

This checkpoint prioritizes NSO/Avatar/TeaMobi 2D, without expanding 3D
support. `rc_acquire` / `img_acquire` no longer dereference a raw Java
`long` before checking membership: they use locked 8192-bucket live
registries, generation checks and atomic refcount claims. The optimized
drawRegion path carries the caller's generation explicitly, as does
Image.Graphics, which previously created a wrapper with no `heap_key`.
Java destruction releases its base ref at most once; stale/foreign fake
handles are ignored. Registry capacity is fail-closed (no untracked handle
is returned to Java).

`j2me_render_stop_for_owner(key)` replaces the global stop barrier. It
blocks acquisition only for the stopped generation and cleanup unlinks
that generation from both live arrays and hash buckets. B's handles remain
eligible while A is stopped. The stop table has 16 entries against the
existing maximum eight registered native heap owners and fails closed
if unexpectedly saturated.

**Scope:** This is a source-level native-handle safety improvement, not
evidence of multiple simultaneous iPhone JVMs. It does not yet address
process-wide Treo/AFK Canvas guard, singleton flush destination, Metal
workspace, JIT, sockets or UI controller ownership. Runtime and device
validation and lifetime-safe zombie thread binding are still required.
No game JAR, Codemagic workflow, main, save/RMS or network code changed.
The bridge remains capped to one live JVM by default.

## 2026-11-22: Late UIKit callbacks and recycled MiniJVM pointers

For the NSO/Avatar/TeaMobi 2D path:
- Swift MIDP screen actions require the origin owner key AND native session
  token after their main-queue hop. The old unowned callback fails closed.
- Alert buttons and timeout dismissal revalidate session, render owner and
  screen revision when delivering input. Alerts while parked remain deferred.
- Controller deinit and late JVM-worker completion cannot reset another
  session's process-wide Treo/GC flags.
- A `JavaThreadInfo` captures `jarbox_native_generation` at the root
  `runtime_create()`. Nested stack frames reuse the same thread info.
  `jarbox_native_heap_key_for_runtime()` compares that immutable key against
  the currently registered JVM ledger key. Display native input, LCDUI and
  the 2D Canvas/Image draw and creation paths now fail closed when an old
  Java runtime has a reused `MiniJVM*` address.

Root bootstrap runtimes created before native ledger registration retain
generation zero and cannot access the MIDP 2D native bridge; the MIDlet
execution runtime is created after native registration. No new timer,
poller, game/network/RMS change, or second JVM activation was introduced.

**Still outstanding:** A forced-zombie pthread executing after the
`Runtime` or `JavaThreadInfo` allocation is freed still risks use-after-free.
This source-level generation check prevents *authorizing B* by comparing only
the recycled JVM pointer, but does NOT solve every JVM teardown memory
lifetime issue, pending Metal callbacks, or the full concurrent JVM registry.
The default single-JVM limit remains 1. iPhone/TSan proof is pending.

## 2026-11-23: Session-owned Java workers and GC; one visible game target

The iPhone build at `61a76cb` was reported successful by the user.
It did NOT demonstrate two running miniJVMs.

Lifecycle foundation now allocates a separate `JarBoxSession` when a
`MiniJVM` is created, and binds the bridge's nonreusable session token.
States: STARTING, FOREGROUND, PARKED, STOPPING, DEAD. The focus bridge
updates those states; only one game window is visible, so the eventual
multi-JVM display model is a focus/token switch (no second window).

The session owns `JarBoxTreoState` (Smart GC, probe and AFK mode mirror);
`garbage.c` now reads `jvm->session->treo_state`. The existing
Canvas guard, NSO fast-path and JAR worker still contain process globals:
these are **explicit blockers** to running two JVMs concurrently.

Java pthreads reserve a reference/worker lease on their session *before*
`thrd_create` and release it after their final VM access. Closing a
session prevents new reservations. `jvm_destroy` no longer treats the
`THREAD_STATUS_ZOMBIE` label as native thread exit, never force-zombies
after three seconds, and retains the MiniJVM heap while a native Java
worker still exists. If a thread is unresponsive, the worker remains in
STOPPING; the existing explicit JarBox process-exit recovery is safer
than a use-after-free. No new UI timer or worker thread is introduced.

**Not yet solved:** JVM-owned collector/shutdown hook edge cases, all
pending native callbacks, Treo/Canvas/NSO/JAR worker singleton migration,
per-session bridge registry and independent concurrent MIDlet runners,
memory admission based on iOS pressure, and full device execution.
Native 3D remains irrelevant for the two TeaMobi 2D JAR target; it
must not cross sessions. `jvm_bridge_supported_concurrent_sessions()`
remains exactly **1**. No iPhone test of parallel JVMs has been done.

Validation for this checkpoint: a host C11 JarBoxSession model compiled
and executed with ASan+UBSan using a locally verified Git blob SHA, plus
source-structure regression tests added to the repository. Full unit
suite, Xcode/Codemagic and device/Tsan remain to be run on this HEAD.

## 2026-11-23: Worker-lease versus STOPPING race regression

Commit `7fdaaecd936b0da3f16d3f99bb7b57fe786c0753` extends
`tools/tests/test_jarbox_session_host.py` with 1,000 fresh-session iterations
racing a native worker reservation against `jarbox_session_begin_stop`.
The test asserts leases are fully returned after joining the contender,
STOPPING denies new leases, DEAD cannot regain foreground, and unique
session tokens are not recycled despite identical synthetic VM pointers.
This is a C11 header-level regression, not a UIKit or real multi-JVM test.
**Execution status at this checkpoint:** committed but not executed in the
current environment; no sanitizer, Codemagic or device pass is claimed.

**Outstanding lifetime blockers:** callback entry points that do not hold
an independently acquired owner/session reference, GC collector and shutdown
hook ordering, and the bridge/renderer/Treo process singletons. Keep the
concurrent-session capacity at one until these paths are audited and tested.

## 2026-11-23: Native lease gate and owned session registry (capacity remains one)

The unified atomic lease gate closes worker and native callback admission before
JVM teardown and tracks every granted lease independently of diagnostic counters.
The bridge visitor now pins its VM through a token-keyed session registry;
the registry retains its own session reference after binding and rejects
retirement until the Java heap is DEAD with no active leases.
The bridge claims max_live=1, while the registry's two-slot model exists only
for future validation. The runtime-reported concurrency limit remains 1.

Host development: a 10,000-iteration callback/shutdown C11 pthread model
passed unsanitized and with ASan+UBSan and TSan; a separate two-slot registry
model passed unsanitized and with ASan+UBSan and TSan. These tests compile
equivalent portable headers, not a complete iOS app. The new Python tests
and Codemagic/device build still need a separate run.

Outstanding: collector and shutdown-hook safety, late native callbacks
outside the guarded visitor, per-VM Treo/Canvas/NSO/JAR worker state,
Metal/3D ownership, and real two-MIDlet scheduling. Do not unlock 2 JVMs.

## 2026-11-23: NSO fast-path signature ownership

The bridge copies the launch-time NSO family / legacy initialization-target
signature into the newly allocated `JarBoxSession.treo_state` before any Java
classes execute. The two NSO native fast-path checks now consult the invoking
Java Runtime's session and its per-session AFK mode, not the process-wide
latest-JAR diagnostic flag. A two-state host regression rejects cross-session
signature/mode leakage. The legacy NSO diagnostic counters, Canvas recognition
telemetry, global renderer state, and JAR load-worker remain shared: this is
**partial isolation only**, not permission to enable concurrent JVMs.

The separate early-Back regression (`ae0c8b5`) permits a STOP-requested
STARTING slot to bind its JVM for safe cleanup, but does not allow callback
admission after cancellation. Codemagic and device tests for these changes
have not yet been run.

## 2026-11-23: Per-generation Canvas AFK and frame callback routing

Commits `9d1a138`, `b029ee5` and this change move interpreter Canvas
elision to the invoking Runtime's session mode; reject stale thread-local
Canvas contexts by immutable native generation; and move Canvas auto-fallback,
AFK repaint-refresh, bypass deadlines and 200-ms paint allowance into the
owning `JarBoxTreoState`. Legacy process-wide `treo_afk_mode` remains as
a compatibility mirror for native 2D/Metal paths, **not** an authorization
for Java bytecode elision. Remaining GPU/guarded instrumentation globals
still prevent 2-JVM enablement.

The renderer now snapshots the flush callback for each native heap generation
at registration and checks registration again before invoking it. Stopping A
unregisters only A; an outdated frame is also filtered by generation at
UIKit drain. The unowned callback ABI is fail-closed when concurrency is
not restricted to one; future multiple JVMs must use owned callbacks.

Portable production-header tests cover A/B callback routing, stale owners,
stop-one-keep-other, and independent AFK/Canvas fallback semantics. They do
**not** establish a complete iOS compile or on-device 2-JVM concurrency.
Single-VM admission and existing Treo modes stay unchanged. No Codemagic,
JAR, save or network code is modified.

## 2026-11-23: LCDUI callback generation snapshot

`JarBoxUIScreenContext` now keeps its own snapshot of the owned/unowned
MIDP callback function pointers when the native heap generation is first
registered. UI notifications resolve only the matching still-live generation
under the context mutex, then re-check focus/render owner before invoking.
Releasing A clears only A's callbacks; a newer GameVC's defaults cannot
rewrite an existing route. The unowned legacy ABI remains restricted to
the enforced one-JVM mode. Swift still revalidates owner and revision after
main-queue dispatch. This is callback ownership, **not** a per-JVM UIKit
window; the single-visible UI target and other native singletons persist.

No Codemagic workflow, NSO JAR, socket, RMS, save or power policy was changed.
Do not report two independent live JVMs until device/runtime tests pass.

## 2026-11-23: Owner-scoped 2D raster/Metal target and texture caches

Native 2D Canvas RenderContext now owns an atomic AFK mode initialized from
its JVM and updated only when the matching immutable heap generation changes
mode. Fast Canvas, opaque fill, image draw, region culling, native replay and
Metal recording check their RenderContext rather than the process-wide AFK
flag. The global flag is retained for older UI/diagnostics and unrelated
pipeline switches; not an authority for another session's 2D draws.

The shared Metal device, command queue, pipeline, vertex buffer and GPU lock
remain process-level; GPU submission is serialized and waited synchronously.
Mutable GPU texture caches and render targets are now dictionary entries
keyed by the native heap generation, not single mutable globals. Each owner
has its own 16 MiB cache bound and cleanup evicts *only* its own entries.
GPU shared workspace and diagnostic Metal replay are **still** a concurrency
blocker; before enabling two JVMs a real iPhone GPU and lifetime stress test
must demonstrate isolation and acceptable memory pressure. This source
checkpoint does not change multi-VM admission from one or enable a new mode.

## 2026-11-23: Explicit token read and callback leases for future tab workers

Native registry now exposes token membership and generation-bound VM
stop checks, rejecting foreign/stale VM pointers without inheriting another
tab's foreground state. Swift `ownsLiveGameSession` uses its immutable token,
not the latest bridge token. A new token-scoped synchronous visitor is
available for future per-tab Treo controls. Focus and park now pin a callback
lease before reading the VM and relinquish it after native operations; STARTING
slots can still park without reading an incompletely initialized heap.

**Not unlocked:** `jvm_bridge.c` still instantiates exactly one
`g_bridge_vm`, and the Swift library uses a single parked controller.
No second Java runner is allocated or started. The runtime capacity remains
one. A separately designed multi-runner bridge and a tab coordinator are
required before two NSO instances can safely be exposed. The existing
one-VM behavior and Deep Treo 8 were preserved for device regression.

## 2026-11-23: Display idle-wait selection by immutable tab token

The Deep Treo Display wait control now pins the exact RUNNING JVM via
`jvm_bridge_visit_running_vm_for_token`, locates its dedicated input
context under the registry mutex, and wakes only that context. Parking A
cannot set B's `display_wait_enabled` flag merely because B became the
foreground input owner. Both the parked controller and its last-resort
cleanup use the token-scoped entry point. The old visible-context API
remains for existing non-tab diagnostics.

The system still runs only one actual `g_bridge_vm`; there is no second
independent native executor or tab coordinator yet. **Do not change the
1-JVM admission cap** until those two are implemented and exercised on
iPhone. This commit alters no network protocol, game JAR or save data.

## 2026-11-24: Native executor slot pool

The singleton `g_bridge_vm` has been replaced by `g_bridge_slots`, an actual
array of independent JVM pointer, token, phase and cancellation fields.
Native init/run/destroy now take a claimed slot, not a global VM. A worker
operation holds its slot until return; finish refuses a busy or live slot
and also requires registry retirement. Stop, callback pin and STARTING
polls select the exact token/VM. Admission still calls the public capacity
function, currently 1. Shared diagnostic buffers, 3D cleanup, launch flags,
legacy render side effects and the library coordinator remain blockers. The
slot pool is not a claim of a working concurrent second MIDlet.

## 2026-11-24: Root library retains independently owned game controllers

The normal library launch path now retains each GameViewController in a
root-owned collection. A managed controller parks its native token and
dismisses only its view; a subsequent selection re-presents the same
controller and restores focus, never starts another MIDlet for that clone.
The weak reverse reference avoids a cycle. Hidden completion removes only
that controller, without dismissing another game's view. STARTING/STOPPING
native tokens are retained and duplicate instance launches are rejected.
Capacity is queried from the native bridge (currently 1). The legacy overlay
path remains a fallback for externally-created controllers. Import/clone
removal conservatively protects live save data. This source change has not
been compiled or validated on iPhone, and it does not unlock two JVMs.

## 2026-11-24: Token-owned bridge diagnostics

Launch errors, bounded NSO/network traces and legacy mod counters now use
independent records keyed by the immutable executor token. The diagnostic
mutex is independent of lifecycle, and snapshots copy into thread-local
storage before unlocking. The Swift runner requests the exact token's
error/trace before retirement; no B launch resets A's record. This is
observability isolation, not evidence of safe concurrent 3D or native JIT.

## 2026-11-24: Park revokes only the selected native destinations

Parking revokes physical input and LCDUI focus alongside framebuffer
visibility, without clearing the hidden JVM's queues or screen data.
A failed partial focus rolls back only its own destinations. The stop
request now pins the target before closing callback admission and wakes
that JVM's Display context even when hidden. UIKit MIDP focus replay uses
the immutable frame generation plus the controller's visible token on the
main queue, rather than deriving the event token from old foreground state.
Single-JVM admission remains enforced. Device testing remains outstanding.

## 2026-11-24: Per-game Treo policy, independently executed per tab

JarBox's two core goals are multitasking and reliable low-overhead Treo.
A game-group preference is stored by installed JAR identity (not clone UUID).
All clones of a JAR use the same Automatic/Compatible preference; changing
it is blocked while the group has live tabs. Different JARs have distinct
preferences. RMS, heap, callback, input and runtime Treo state stay per tab.
Automatic parking uses guarded mode 8 only after that particular JVM has
verified both NSO archive family and Canvas shape; otherwise mode 1 with
normal GC and Display is selected. Launch recognition is local before it is
copied into the JVM, not read back from shared launch flags. Deep-mode guard,
GC, Display wait and renderer transitions execute under a control mutex;
late Canvas fallback turns off the owner's wait, restores safe GC, and
updates owner raster before another resume can interleave. The compatibility
mirror remains only for single-admission diagnostics. Per-tab information
reads actual mode by token and no longer attributes global counters to a
single JVM. Legacy manual diagnostic blackouts still need audit in multi.
Admission remains 1; device and full CI validation are outstanding.

## 2026-11-24: Interpreter profile and 3D Canvas/MC3D workspace isolation

Interpreter NSO-init trace checks now read the invoking runtime's session;
mode-9 direct-graphics dispatch also selects that runtime's mode. Legacy
A/B graphics flags are only used by this interpreter dispatch when admission
is one. M3G and MascotCapsule pixel transfers borrow an existing generation-
checked RenderContext reference, drain queued 2D work before pixel access,
and release the reference on return. Foreign/expired handles are rejected.
MascotCapsule EAGL context, framebuffer/renderbuffers and saved context are
now per heap generation; cleanup after worker drain removes only that key.
The M3G engine's EGL context, interface list and pixel workspace are still
shared. OpenGL native handles/GL thread semantics and all device rendering
paths remain unverified. These source changes do not enable concurrency.

## 2026-11-24: Readiness gate coverage for Treo and M3G teardown

At base commit `ef81be891d7cfa932b21cf3ca669dc89ff0a7180`, all seven owned-component
source predicates matched, but five previously reported blockers remained.
The bridge also calls the process-wide `j2me_m3g_cleanup()` during slot
destruction; M3G interface and pixel workspace ownership remains unresolved.
Report this separately as `3d_global_m3g_cleanup`. The new
`source_prerequisites_met` field requires every reported ownership predicate
(including Treo/Smart GC) and no detected blocker. It is a source-only
prerequisite, not evidence of actual concurrent JVM safety.

Validation: existing audit predicates were evaluated against the SHA-pinned
GitHub source through the connector. The new synthetic-fixture regression
passed locally (1 test); both modified Python files passed py_compile.
Original Python blobs and the tested replacement blobs were hash-checked.
A complete repository checkout, full Python suite, native iOS build,
Codemagic and device validation were not available in this environment.
The native runtime and the single-JVM admission cap are unchanged.

## 2026-11-24: Back requires a running owner and confirmed native park

P1 single-VM behavior: the managed library path previously cancelled the
startup watchdog before checking the global bridge phase; the legacy
overlay path hid the render destination even if native park/Treo was
refused. Back now checks the exact token via the existing pinned
`treo_mode_for_token` visitor before altering diagnostics or input, and
both paths share a single park attempt. The watchdog is cancelled and
the visible game detached only after `parkedTreoActive` is confirmed.
No new timer, native API, or runtime admission change is introduced.

Validation: the SHA-pinned original Swift method was reproduced in a
local source fixture. The new Python source-contract regression failed
on the original method and passed on the replacement (1 test).
`swiftc -frontend -parse` accepted the replacement method in a dummy
class; this is syntax checking, not UIKit type checking or execution.
Full checkout, iOS build and real Back/Treo/resume device tests remain
outstanding.

## 2026-11-24: Late completion must not infer an empty registry from token zero

The Swift worker completion has already verified that its own immutable
token is retired. The implicit session-token API returns zero both for an
empty registry and for multiple parked owners without a selected tab.
Consequently, it cannot authorize process-wide diagnostic/Treo resets.
Require `jvm_bridge_active_session_count() == 0` instead. The existing
foreign-owner early returns remain in place; this changes neither
admission nor per-owner stop/cleanup. The current one-VM behavior is
preserved.

Validation: the updated source-contract predicates were executed against
the exact SHA-pinned Swift text (old source rejected, replacement accepted).
A standalone Swift host model of the guard compiled and returned reset=true
only for count 0, false for counts 1 through 4. This is not a UIKit build
or a real JVM concurrency test. Python full-suite and device validation
remain outstanding.

## 2026-11-24: Route memory-pressure Smart GC fallback to retained owners

The UIKit memory-warning callback previously depended on the manual
`jarBoxSmartTreo` flag, so automatically parked Deep Treo could miss the
warning. It also selected an implicit JVM. The callback now requests
fallback via the retained controller's immutable token, using the existing
pinned running-VM visitor. The library forwards its own warning to all
retained game controllers (including the legacy overlay owner). The native
operation is idempotent and only marks fallback when Smart GC is enabled.
An inactive/foreign token cannot affect another JVM. This restores normal
500 ms Smart GC cadence without changing the actual Treo render mode,
Canvas eligibility, network, save state, or the concurrency cap. No new
timer or worker.

Validation: `test_multivm_memory_pressure.py` passed locally (1 test,
mock bridge visitor). The production TreoState header was reproduced and
verified against Git blob SHA `5c46be8e68243a18203c34773f3f39164aefbe70`;
the harness compiled the actual fallback visitor and proposed wrapper
from a source excerpt. It checks two independent states, repeat warnings,
disabled Smart GC, unknown/zero tokens and no implicit visitor use.
UIKit routing was checked against the SHA-pinned source replacement.
Full native build, complete test suite and device memory-pressure behavior
are not verified.

## 2026-11-24: Persist late Canvas rejection across automatic repark

A session that already fell back from guarded mode 8 to compatible mode 1
could be promoted to mode 8 again on the next Back, because positive Canvas
recognition remained set and rearming the guard reset its diagnostic fallback.
Record a separate sticky per-session rejection when the late guard fires.
Automatic parking must reject mode 8 for this JVM until it is destroyed,
even if another positive Canvas sample arrives. Another clone and a fresh
JVM still qualify independently. Legacy per-run diagnostic guard flags
retain their prior semantics; the installed JAR preference is unchanged.
Existing transition serialization, GC and Display fallback are unchanged.

Validation: reproduced the production header locally and verified its Git
blob SHA against the base commit. The new Python regression compiled the
header with C11, rejected the original header at the expected repark
assertion, and passed with the replacement (1 test). The same C harness
passed 50 executions under Clang ASan+UBSan, each exercising 100
park/resume transitions and independent clone/restart state. These are
header-policy tests, not iOS rendering or real JVM concurrency evidence.
Full checkout, native build and iPhone validation remain outstanding.

## 2026-11-24: Escalated Stop holds a heap lease, not the lifecycle mutex

The stop watchdog previously called thread_stop_all under the global bridge
lifecycle mutex. Java monitor acquisition can block there, preventing other
sessions from making lifecycle progress. Resolve the exact RUNNING,
stop-requested owner under that mutex and reserve its session callback
lease before unlocking. A stop request denies ordinary registry visitors,
but the targeted escalation may acquire this lease until actual cleanup
closes the gate. Perform thread_stop_all outside the global mutex, then
release the heap lease. The destruction path must still drain all leases.
No change to admission or cooperative stop policy; the internal Java
monitor/thread-list lock order remains a separate runtime audit item.

Validation: compiled the exact original and replacement function excerpts
with SHA-verified production JarBoxSession/TreoState headers and a mock
VM/monitor boundary. The original failed the lifecycle-mutex trylock
assertion; both new regressions passed after replacement. The escalation
harness passed 50 ASan+UBSan executions of 100 modeled stop/cleanup cases
each, checking stale and non-running tokens, closed gates, the live lease
during cleanup, lease release and unchanged session B. The model simulates
cleanup after unlock; it does not run real Java monitors or two miniJVMs.
Full checkout, full unit suite, TSan, Xcode/Codemagic and device tests
remain outstanding.

## 2026-11-24: Serialize native focus/park against destructive cleanup

An owner callback lease protects the Java heap but does not by itself order
renderer/input/LCDUI publication against teardown. An admitted focus could
otherwise reattach a destination after cleanup had revoked it. Serialize the
explicit bridge focus/park calls and cleanup admission closure with a separate
transition mutex. Acquire it before the lifecycle mutex; release both before
destructive cleanup or waiting on Java threads. The installed UIKit callback
dispatches asynchronously, not synchronously back into bridge focus. No
poller, new admission capacity or change to Treo policy is introduced.
Startup registration, runner-exit publication, other callback classes and
device lock-order verification remain separate audit items.

Validation: locally compiled the matching production focus/park and cleanup
admission excerpts with SHA-verified JarBoxSession/TreoState headers and
mock native destinations/registry. The legacy excerpt (adapted to the test
helper boundary) failed the transition-lock assertion. Both new unit tests
passed on the local source fixture. The threaded harness passed 50
ASan+UBSan runs of 100 modeled cases each, including partial-focus rollback,
hidden A park preserving B, and focus racing actual cleanup admission.
Only the excerpt and header model were compiled, not the complete bridge,
UIKit or two running JVMs. Full checkout and iPhone build/test remain pending.

## 2026-11-24: Deferred haptics recheck the exact JVM's Treo mode

The Java vibration entry point checked its own runtime mode, but its
deferred main-queue block still authorized hardware activity using the
process-wide AFK mirror. Capture only immutable session token and native
heap generation, and recheck the exact running owner's mode via the
existing pinned visitor. Verify visible identity after the visitor as well.
Reject invalid, parked or retired requests before touching the shared
player, and recheck after player creation before starting it. No Runtime
or MiniJVM pointer crosses the asynchronous boundary. The process-wide
haptic engine and teardown, queued callbacks across same-owner park/resume,
and physical device execution still require audit; this is not an atomic
hardware/focus transaction or evidence of safe multi-JVM execution.

Validation: the source-contract test rejected the original haptic excerpt;
both new unit tests passed on the replacement fixture. The actual C
authorization helper compiled with mocked mode/visible-owner lookups and
passed 50 ASan+UBSan runs, each checking 100 repetitions of owner/mode
cases including focus changes during the visitor. The Objective-C
CoreHaptics implementation and complete app were not built or executed
on this host. Admission remains 1; no changes to Codemagic, JAR or RMS.

## 2026-11-24: Keep the pthread start result outside the child's Runtime

The child can finish and become eligible for Runtime finalization before
thrd_create returns to its caller. The parent previously returned the
pthread field through the potentially finalized Runtime, and supplied
that field as thrd_create's output location. Return a creator-local
handle instead. The worker already records thrd_current() on entry.
Failure and STOPPING lease-release paths are unchanged. This does not
establish lifetime safety of all Java thread/finalizer paths.

Validation: SHA-verified production JarBoxSession and TreoState headers
and matching function excerpt used in the local C model. Original
excerpt failed ASan with heap-use-after-free when the mocked child and
collector completed before thrd_create returned. The replacement passed
two Python regressions and 50 executions under Clang ASan+UBSan (100
modeled starts per execution, including creation failure and STOPPING).
Updated the existing teardown source assertion for the local handle;
the full existing suite was not executed. Full JVM, Xcode/Codemagic,
TSan and iPhone validation remain outstanding. Admission remains one.

## 2026-11-24: Make GC STOP/DEAD terminal under concurrent controls

The collector status previously used unsynchronized reads and ordinary
writes across threads. A late pause/resume could overwrite STOP, and
another stop could overwrite DEAD, preventing teardown from observing
completion. Use an atomic status read and CAS control update that refuses
to change STOP or DEAD. The collector publishes DEAD with a release store.
Existing VM share lock ordering, GC cadence, heap thresholds and Treo
mode selection are unchanged. Java reflection diagnostics now use the
atomic accessor too. Audited direct references in the core JVM C files.
This does not yet join the collector pthread or handle its creation
failure; those are separate lifetime audit items.

Validation: the original control excerpt, compiled against the new status
accessor in a mock VM harness, failed the terminal STOP assertion. The
replacement passed the new Python unit test and 50 ASan+UBSan executions,
each exercising 100 pthread pause/resume/stop races and independent
collector B state. Tested helper/control excerpts and the regression file
were matched against the committed replacements. The complete GC,
miniJVM, TSan, Codemagic and iPhone tests were not run here. Admission
remains one.

## 2026-11-24: Cancel incomplete startup and remove game-exit animation

User reports occasional stuck startup, inability to close, and an unwanted
vertical dismissal transition. During startup the Back control now reads
"Hủy mở game" and requests cooperative cancellation, not Treo. Once the
first usable game screen completes the startup watchdog, normal Back
continues to park a running owner. A stale Alert cannot clear that
watchdog. Stop displays "Đang dừng…" without claiming native retirement.
The worker checks its exact stop token before preparing storage and again
before native init. Game controller dismissals are nonanimated; the slot
and controller remain protected until native retirement. No forced heap
free, RMS edits or admission increase.

Validation: five new Python source-contract regressions failed on the
original relevant source fragments (4 failures, 1 error) and passed on
the replacement fixture; swiftc -frontend -parse accepted the rewritten
method excerpts in a dummy class. The modified existing park source
guard accounts for the no-owner escape hatch. Full source checkout,
UIKit type checking, startup cancellation timing, Codemagic and device
tests have not been run. Native deadlocks require separate fixes.

## 2026-11-24: Release thread-list lock on GC abort and stop collector before Java drain

The pause-world failure path returned without releasing the Java
thread-list spinlock. This could block forced stop and future worker
operations. Release that lock before the caller resumes Java, and clear
the in-progress GC flag on the aborted collection path. Explicit bridge
escalation, bridge destruction and JVM destruction now request terminal
GC STOP before taking the thread-list lock in thread_stop_all, so a
collector waiting for a stalled Java worker can leave its suspension
wait. STOP is requested through the existing atomic GC control helper
rather than acquiring the VM-share lock. The existing worker/callback
lease drain and heap cleanup barriers are retained. No RMS changes.

Validation: the original production pause-world excerpt failed the
modeled cross-thread mutex probe; source-order regressions also failed.
After replacement the new three regressions plus the updated stop
escalation regression passed (4 tests). The production excerpt was
matched by checksum and the two regression files by Git blob SHA.
The modeled pthread harness passed 20 ASan+UBSan runs (100 abort and
100 successful pause paths per run). These are host excerpt/model
tests, not the full GC or a measured iPhone shutdown. Remaining work
includes GC pthread join/creation failure, native monitor wake paths,
full suite and device validation. No concurrency increase.

## 2026-11-24: Cancel before expensive native startup and RUNNING publication

Honor the exact slot's stop flag before archive recognition and again
before heap allocation. If cancellation has already won, return -9;
the owning Swift worker still retires the empty slot. Once initialization
has acquired resources, keep the existing cleanup path. In bridge_run_slot
check cancellation under the lifecycle lock before publishing RUNNING;
a previously cancelled launch must not briefly look runnable to another
visitor. This is cooperative cancellation at safe checkpoints, not
preemption of an arbitrary native call. No fixed minimum startup delay,
RMS change or concurrency increase.

Validation: compiled the matching production runner excerpt in a host C
harness with mocked MIDlet/session boundaries. Baseline aborted
(SIGABRT); replacement passed one Python regression and 20 ASan+UBSan
executions of 100 modeled cancel/normal/duplicate-run sequences. The
native init checkpoint order was checked on the exact connector source
and replacement using equivalent source predicates; the complete
Python suite, native build and device execution are still unverified.

## 2026-11-24: Single-flight game presentation and coalesced stop UI

Both library launch and resume now share a main-actor presentation gate
that is claimed before calling UIKit and released by its completion,
not an arbitrary delay. Collection selection checks the gate before
reading clone metadata. Clone save-root validation happens once on the
startup worker, before native init; removing redundant UI-thread
preflight does not remove the worker's ownership and symlink checks.
A second stop/back tap while closing no longer shows a premature
recovery warning: the existing rescue watchdog (or failed worker
retirement) enables recovery, and a weak alert identity prevents
duplicate recovery presentation. The live native token still blocks
reuse until retirement. No new polling, forced heap free or RMS change.

Validation: a host Swift harness compiled the exact presentation helper
and passed 1,000 modeled presentation cycles with 100 duplicate taps
during each transition. The equivalent source contracts for both entry
points and recovery gating failed on the old connector source and passed
on the replacement. The regression file was hash-matched to the host
test. UIKit presentation, full suite, Xcode/Codemagic and actual iPhone
latency/data safety require device testing. Admission remains one JVM.

## 2026-11-24: Start GC only after bootstrap and join the collector before heap cleanup

The old gc_create returned success even if thrd_create failed, then
gc_destroy could wait forever for a DEAD signal from a nonexistent
thread. Split collector resource initialization from worker startup.
Start the worker once after Java bootstrap; propagate creation failure
to the existing launch-failure path and suppress normal shutdown hooks
for that failure. An unstarted collector is cleaned without waiting for
a worker. A started collector is joined without holding the VM-share
mutex before heap cleanup; on join error retain the existing final
DEAD-access barrier. This removes the initial PAUSE sleep for successful
startup. No admission, Treo cadence, storage or network changes.

Validation: host unittest ran two tests successfully against a fixture
containing the exact replacement gc_start/gc_destroy excerpt and a
minimal bootstrap source fixture. The full SHA-pinned source ordering
was also checked through the connector (baseline rejected, replacement
accepted). Clang ASan+UBSan passed 50 runs of the same harness, each
with 100 real pthread joins, 100 injected create failures and 100
unstarted collector destructions. Collection, heap clearing and VM
locks are mocked; join-error fallback, full app and device tests remain
unverified. No concurrency increase.

## 2026-11-24: Normalize VM-share absolute wait deadlines

The shared VM condition wait added fractional milliseconds to tv_nsec
without carrying into tv_sec. On a second boundary this generated an
invalid absolute deadline, so the condition wait could return immediately
without releasing the VM lock. Normalize the deadline, handle a failed
clock read, and clamp negative delay to zero. No new timer, change in
requested cadence, Java monitor policy, storage change or admission
increase. This fixes the deadline computation; lock-order safety and
real device latency are separate concerns.

Validation: compiled exact SHA-pinned old/new vm_share_timedwait excerpts
against a mock clock and condition wait. The old code failed the first
boundary assertion (unittest error, SIGABRT); replacement passed
one Python regression and 50 ASan+UBSan executions, each checking
11,000 combinations of clock fraction and wait duration plus explicit
boundary, negative delay and clock failure cases. The mock does not
measure actual scheduling or mutex release on iOS. Full suite, build
and device validation remain outstanding.

## 2026-11-24: Release bootstrap Runtime when a required class is missing

Check all four required core class lookups before creating instances.
Reuse the validated Thread class and funnel all results through one
temporary Runtime/string cleanup path. On a missing class, set exit_flag
so the failed startup does not launch shutdown hooks. Transfer objects
to the collector before destroying the bootstrap Runtime. No change to
successful class initialization order or storage, Treo policy, admission,
or MIDlet execution. This handles missing class lookup results, not all
allocation or class-initializer failures.

Validation: host unittest compiled the matching C excerpts with mocked
class loading and heap operations. Baseline failed the cleanup assertion
when Integer was missing; replacement passed (1 test, 0.066s). Twenty
ASan+UBSan runs passed, each with 100 repetitions of four injected missing
classes and a successful bootstrap. The complete miniJVM, native app,
Codemagic and iPhone tests were not run. Admission remains one.

## 2026-11-24: Unify native startup rollback before MIDlet execution

The five post-allocation native initialization failure paths called the
ordinary jvm_destroy path even though no MIDlet had run. Centralize the
rollback helper: latch the exact slot's stop flag, mark forced shutdown
to skip normal Java shutdown hooks, preserve the existing worker/lease
drain, clear the pointer only after destruction, and reset legacy mirrors
only in the one-VM build. Existing native resource release ordering is
unchanged. Also honor cancellation immediately after Java bootstrap,
before registering additional native resources. Admission and save
storage are unchanged; this is not a general solution to monitor
deadlocks or allocation failures.

Validation: host unittest executed the matching C helper with mocked JVM
destruction (1 test, 0.066s). Twenty ASan+UBSan runs passed, each with 100
modeled rollbacks and a separate untouched owner. Equivalent source
predicates on the SHA-pinned full bridge rejected the original and
accepted the replacement, including all five failure branches and
the new cancellation checkpoint. The full Python suite, iOS build,
real shutdown hooks and device timing/data integrity remain unverified.

## 2026-11-24: Reset library navigation after the last game stops

User reports a stale "Đang chạy ẩn" title and Stop action after closing
a game. The old empty-liveGames branch only updated the left item, leaving
the previous title and right-side Stop item untouched. Rebuild all three
navigation properties from one live-games snapshot, and preserve the
native registry check. If no resumable owner remains but a native slot
is still occupied, show recovery rather than a fake running tab or an
idle library. Once the registry is empty, restore "Thư viện" and only
the ordinary import/menu actions. No new polling, changes to JVM stop
behavior, storage, or admission.

Validation: host Swift unittest using the exact old/new method excerpts
(with Objective-C selectors replaced by opaque names and UIKit/registry
test doubles) reproduced the stale "Đang chạy ẩn: B" title on the old
method. Replacement passed 1 test (0.538s), exercising 1,000 modeled
cycles of multiple live owners, stopping, retirement and stale controller
references, plus direct live-to-idle transition. Updated the old source
guard for the snapshot expression; the full existing suite, UIKit build,
and iPhone verification were not run. This is a UI state fix, not proof
that every native stop completes.

## 2026-11-24: Request collector STOP before Java-initiated exit drains workers

The native Runtime.exitInternal path bypassed the GC STOP request already
present in the host-driven teardown paths. It could enter thread_stop_all
while a collector held the thread-list lock waiting for Java safepoints.
Request terminal GC STOP for this JVM before entering the drain. Preserve
the Java exit code and existing lifetime barriers; do not change Java
monitor wake semantics, storage, Treo policy or admission.

Validation: the host C test compiled the exact old/new JNI function
excerpts with a modeled GC state and real pthread mutex/worker. Baseline
failed the STOP-before-drain assertion; replacement passed 1 test
(0.075s) and 20 ASan+UBSan runs of 100 modeled exits each. Also checks
repeat exit with DEAD status and isolation from a second collector.
This does not execute the real Java monitor or GC implementation.
Full suite, iOS build and device validation remain outstanding, as does
the thread_stop_all monitor lock-order audit.


## Library navigation: return to last parked tab

Keep the library title and import/menu bar stable across live and stopped
sessions. The global menu offers "Vào Tab cuối" using a weak reference to
the exact most recently parked managed controller (legacy overlay retains
its existing owner). Revalidate live ownership and presentation admission
at invocation; a stopped last tab disables the action rather than opening
another clone or a fresh JVM. Ordinary stop remains in the per-game icon
context menu and is labeled "Thoát game" in the in-game menu. Native stuck
session recovery remains available when no resumable owner remains. Rename
the global sleep screen to "Bảo vệ màn hình" without changing Treo runtime,
existing sampling, storage, or admission. Updated the navigation host
harness and source guards. iOS/Codemagic and full suite remain to be run.

## Last-tab identity: snapshot the parked native token

Remember the exact controller and its current parked session token at a
successful park (or legacy overlay creation). Require both retained identity
and the same live parked native token on menu activation; no fallback to a
different controller or a reused token. Clear the snapshot on retirement.
Recheck that there is no live owner before opening the exceptional recovery
action, since a previously constructed menu may be stale. No changes to
the library layout, native stop, Treo mode, save paths or JVM admission.

Validation: isolated Swift host model of the menu and owner predicates
passed 1,000 cycles, including token replacement, live-but-not-parked,
stale activation, presentation gate, retirement, and legacy overlay.
Repository regression expanded to extract the production methods and
check the token/recovery guards. Full test suite and iOS build not run.

## Java monitor shutdown: targeted, sticky wait wake without monitor acquisition

Previously thread_stop_all held the VM thread-list lock and called
jthread_lock on a waiting thread's Java monitor; that monitor could be
owned by a worker needing the list lock to finish. A bare condition signal
would also race wait registration. Replace Java Object.wait/park's
monitor condition wait with a stack-owned wait node and private condition.
Publish under the thread-info lock and the monitor wait-set lock, latch
signals before sleeping, and remove both publications before destroying
the node. No path holding the private waiter mutex acquires a publication
lock or Java monitor. Stop/interrupt wake the target without claiming its
monitor; notify selects one unsignalled node and notifyAll signals all.
Restore the full recursive monitor depth after wait, keep the Runtime
blocking until the monitor is reacquired, and preserve interrupt handling.
The VM-share condition remains unchanged. No timer or polling is added.

Validation in a standalone Linux C11 host harness using the replacement
function bodies and modeled Runtime/GC/spinlock plumbing: 100 cycles
passed with -Wall -Wextra -Werror; 20 ASan+UBSan runs (2,000 cycles)
passed. Tests cover held monitor at stop, targeted stop and interrupt,
pre-interrupt, timed wait, notifyAll, recursive monitor reacquisition,
and waiter detachment. Repository regression extracts the production
functions. Full native runtime, TinyCThread, existing full suite, TSan,
Xcode and iPhone remain unvalidated. Java monitor entry contention,
legacy volatile stop flags, native target Runtime lifetime, Unsafe
unpark and shutdown hooks/finalizers still need audit. No changes to
RMS, networking, Treo policy, worker lease barriers or concurrency cap.

## Java worker launch rollback and native handle ownership

Move the NEW -> RUNNING claim into jthread_start, serialized by the
thread-info lock; JNI and shutdown hooks both use that same claim.
Reserve the session before registration and creation. A denied admission
leaves the unstarted Runtime linked to its Java Thread; a cancelled or
failed pthread creation removes the list entry and marks it terminal,
but retains stackFrame for GC finalization rather than leaking the
allocation. The JNI caller reports unsuccessful launch instead of false
success and detaches successfully created ordinary Java workers; a
shutdown hook joins only a valid handle, stops starting hooks once
exit_flag is set, and still relies on the worker-lease teardown barrier.
No change to the worker's success-path ownership or JVM admission.

Validation: local standalone C11 harness using the replacement
jthread_start body with modeled session, GC, locks and synchronous
fast-child completion: 10,000 scenarios PASS (-Wall -Wextra -Werror);
20 ASan+UBSan runs PASS (200,000 modeled scenarios). Cases include failed
creation, stop during registration, admission rejection, duplicate
start and child completion before create returns. Updated the repository
host regression to use production session policy and extracted start
body; the full repository test suite, actual detach/join behavior, GC
reclamation, iOS build and device validation have not been executed here.
Shutdown-hook GC roots, monitor entry, forced-stop monitor ownership,
finalizers and remaining volatile-field races are separate blockers.

## Shutdown-hook queue is a per-VM GC root

The registered hook array previously was not included in GC's strong root
snapshot. Retain its entries in the owning collector's runtime_refer_copy
under the hook-list lock; never copy roots from another JVM. During
normal teardown keep the front hook rooted until its start and join
finish, and retain it if joining fails. After all worker and callback
leases drain, clear the queue under its lock before final GC. Reject
null hooks and registrations during exit/STOPPING, including finalizer
attempts during heap destruction. Existing forced host shutdown still
skips hooks. No extra polling or timer.

Validation: local C11 model of the exact root-copy helper passed 10,000
cycles; 20 ASan+UBSan repetitions (200,000 modeled cycles) passed. This
checks independent VM snapshots, null entries and empty queues using
modeled arrays/locks; it is not a real GC, Java hook execution or
concurrency stress test. Added repository extraction regression and
source-order guards. Full suite, real GC/hook lifetime, Codemagic and
iPhone remain unvalidated. Blocking healthy hook execution and monitor
entry/finalizer cancellation remain open.

## GC deferred-object list: avoid finalizer/weak-reference self-cycle

A single unreachable instance could qualify for both finalize() and
weak-reference enqueue. The old code linked that same MemoryBlock into
the deferred remark chain twice, setting tmp_next to itself if both
branches ran. This can prevent GC from returning and block JVM shutdown.
Process each instance's existing callbacks in the same order, link once,
and unlink each node while remarking. Check terminal collector STOP
at dispatch boundaries and still remark previously processed objects.
This does not interrupt an already executing Java callback, solve
finalizer resurrection semantics, or change Treo scheduling.

Validation: Linux clang C11 (-Wall -Wextra -Werror) standalone harness
using the exact new helper body and modeled Java callbacks/heap passed
10,000 cycles. ASan+UBSan 20/20 runs passed (200,000 modeled cycles).
Cases: both callbacks on one object, multiple objects, STOP during
either callback, initial STOP/PAUSE, previously finalized objects,
marked targets/instances and independent collectors. Repository
regression extracts the helper and guards its ordering before sweep.
Full repository suite, actual Java finalizer/weak-reference behavior,
Xcode and iPhone not run here.

## Owner-local 3D supersampling configuration

Move the launch scale from the process-global g_render_3d_scale to
JarBoxSession, configured before jvm_init. M3G bindGraphics, setViewport
and releaseGraphics read the calling Runtime's session; the existing
MascotCapsule Java property receives the same owner's configured value.
Preserve the previous positive-scale/default-one policy. No renderer
allocation, pixel data, EGL teardown or Treo behavior is changed.

Readiness now checks positive scale ownership and explicitly lists the
still-global M3G pixel buffer and EGL context as blockers in addition
to global M3G cleanup. Admission remains one JVM. This is configuration
isolation only, not proof of M3G or device concurrency.

Validation: Linux clang host model compiled the exact scale accessors
with -Wall -Wextra -Werror, 10,000 cycles PASS and 20/20 ASan+UBSan
runs (200,000 modeled cycles). Covers separate session values, zero/
negative defaults and owner-local reconfiguration. Repository tests
extract the accessors and guard launch and renderer wiring. Full
repository suite, Objective-C/iOS build, actual 3D output and device
validation remain outstanding.

## 2D-first: deny new Metal work for hidden Canvas generations

2D TeaMobi games (NSO, Avatar) are the primary target. Leave the existing
single-session 3D engine intact; full multi-3D work is not a requirement
for a future explicitly guarded 2D-only multi-session mode. Admission
remains one JVM until the 2D path and exclusion of unsafe 3D usage are
proven.

A visible-key transition can precede Treo mode application. Previously
the Metal recorder/drain checked mode but did not check current visible
generation. Require the owner-local non-AFK predicate and visible key
for recording, GPU workspace admission, and again before command
submission; check the same predicate before Canvas snapshot/delivery.
If denied, retain existing ordered CoreGraphics fallback, including
commands already recorded. No global GPU purge, new timer, delay, or
extra per-session GPU buffer is introduced. In-flight commands may
finish; these checks are not a lock-linearized revocation or GPU
lifetime proof. Shared serialized workspace remains a readiness item.

Validation: standalone Linux clang harness using the exact new predicate
and modeled RenderContexts passed 10,000 sequential transition cycles
and 100,000 concurrent stale/missing-owner checks. 20/20 ASan+UBSan
repetitions passed. Repository regression extracts the helper and
checks recording/submit/flush wiring. No full repository test suite,
Apple Metal build, on-device power measurement, or iPhone test run.

## 2D LCDUI: bind Form/List/Alert input and staged text to its original generation

A revision check in UIKit is not enough when a focus or slot-reuse
transition occurs before posting an event. Store the native heap key in
the input binding; the new owner-bound touch API checks that key and
enqueues under the input-context lock. Form and List views capture the
generation from the owned callback, capture it in menu closures and use
the new API for commands/selection. Alert callbacks carry the same
existing origin key down to the queue. Stage Form text/choice data into
one explicit screen context under the registration and pending-text
locks, checking generation and revision without re-resolving the
focused context between validation and write. Legacy unowned text
staging remains single-VM only.

This is a targeted LCDUI route fix, not all physical key/touch ownership
or a full Java/Swift callback lifetime proof. No RMS, JAR, networking,
Treo algorithm, 3D or admission changes.

Validation: Linux clang C11 standalone harness of the exact new
owner-bound input function with modeled queues, 10,000 transition cycles
and 300,000 concurrent submissions PASS. 20/20 ASan+UBSan repetitions
PASS. Source regression verifies the input binding and all three UIKit
paths. Full repository suite, UIKit/Objective-C compilation, real
form submission and iPhone validation remain outstanding.

## 2D Canvas controls: session-bound input and event-driven repeat cancellation

Physical pointer, joystick, number pad, soft key and directional pad
events previously used the currently focused input destination. Bind
the immutable launch token to the native input slot and to the controls.
Validate it under the input-context mutex at enqueue; a parked, retired
or reused slot cannot redirect an old event to a different launch.
Cancel active pointers and held keys, and invalidate the existing
joystick/numpad/direction repeat timers before Back revokes focus,
before stop/blackout and when switching to Form/List. On worker
completion cancel local controls even when a different tab is alive.
Timer callbacks validate their identity and launch token. No new
timer/polling mechanism, engine 3D, RMS, network or admission change.

Validation: standalone Linux clang C11 harness of the exact three new
native token-routing functions with modeled input queues ran 10,000
sequential cycles and 300,000 concurrent submissions PASS; ASan+UBSan
20/20 PASS. Repository test extracts those functions and adds source
guards for the Swift wiring. Swift UIKit compilation, real Java input
delivery, full repository tests and on-device CPU savings not measured.
