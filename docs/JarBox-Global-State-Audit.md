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
