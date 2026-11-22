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
| `garbage.c:321` | `treo_gc_probe_requested_ms` | P | M | Smart-GC probe interval is global → Treo of one JVM changes GC cadence of another. Part of Treo/Smart-GC per-VM work. |
| `garbage.c:400-402` | `g_native_heaps[]` ledger | V | — | Already per-JVM with generation key (done). |
| `hashset.c`, `hashtable.c` | default-size statics | P | — | Read-only after init (not truly mutable). |
| `ssl_client.c` | `ca_crt_rsa` / `g_ca_bundle_once` | P | M | **Fixed in source:** CA bundle assembled under `pthread_once` and read as immutable thereafter. Full ssl_client/mTLS host and iOS builds not rerun; harness stubs TLS. |

## B. Native bridge (`NativeBridge`)

| Where | Variable | Scope | Risk | Status / fix |
|---|---|---|---|---|
| `jvm_bridge.c:101` | `g_bridge_vm` (single JVM) | P | **H** | The one-JVM limit itself. Replace with a session registry (UUID, generation, state, stop flag, controller). |
| `jvm_bridge.c:20,24`, `treo_*` | `treo_exact_ninja_verified`, `treo_nso_init_target_active`, NSO traces | P | **H** | Treo/NSO state is per-process; one game's Canvas guard can change another's mode. |
| `j2me_render.m:197,289-342` | `treo_afk_mode`, `g_afk_refresh`, `g_afk_needs_redraw`, guarded-AFK flags | P | **H** | Deep-Treo mode is global: parking A would park B. Must move into a per-VM `TreoState`. |
| `j2me_render.m:1586` | `g_render_stopped` | P | **H** | `j2me_render_stop()` is called from every JVM's shutdown and stops *all* rendering (see `jvm_bridge.c` Step 1-2 comment). |
| `j2me_render.m:167-176` | `g_flush_callback`, `g_visible_render_owner_key`, `g_haptic_player_owner_key` | P | M | Owner-checked now, but single destination. Needs per-VM display destination. |
| `j2me_render.m:1591-1674` | `g_live_rc[]`, `g_live_img[]`, `g_dead_*` | P/V | M | Handles carry owner key; list is shared with one lock. Acceptable if every lookup is owner-checked (open item: raw-handle paths). |
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
2. Per-VM `TreoState` (Treo mode, guarded-AFK, GC probe) — highest behavioural risk.
3. Per-VM render stop flag instead of `j2me_render_stop()` global.
4. Micro3D / M3G context ownership.
5. Session registry replacing `g_bridge_vm`; then, and only then, lift the one-JVM cap.

## 2026-11-22 checkpoint: host verification unavailable

- `git am` on a temporary empty checkout failed because original miniJVM source files are not present; the supplied patch was applied as exact Git blobs through GitHub's Git API instead (all eight blob hashes matched the format-patch).
- `tools/host_multivm_smoke/run.sh plain 2`, `asan 17`, and `tsan 3` returned exit code 2 before compilation because this execution environment could not fetch the complete repository. Old TSan logs were cleared first. These commands do **not** revalidate either `jnienv` or the CA/RNG changes.
- The documented 51/51 sanitizer result is user-provided earlier evidence only; the host harness does not exercise UIKit, render, audio, 3D, TLS, or JIT. The single-JVM safety limit remains in place.
