# JarBox Multi-JVM: architecture lessons from J2ME NST 1.0.0 IPA

**Reviewed:** 2026-11-23 (static inspection only)
**Input SHA-256:** `be799d59828a220649c1a27626ddf4759d0374d84c48159ceb4573bd7ef970d6`

This note records architecture clues from a user-provided third-party IPA.
No third-party implementation code or binary is copied to the repository.
Field names and constant values were checked against ECMA-335 metadata
in `J2me.iOS.dll`, `J2me.Midp.dll`, `J2me.Vm.dll`, and `J2me.Host.dll`.

## Direct observations

- The iOS host is .NET/Mono AOT. `MicroController` has `_slots`, `_current`,
  `AddSlot`, `Select`, `UpdateFocus`, `CloseSlot`; its metadata constant
  `MaxSlots` is **100** (not a verified device capacity).
- Each `IosSlot` has `Session`, `FrameLock`, `Frame`, `FrameDirty`,
  `Screen`, and `Config`. `CanvasView.Buffers` is **3**.
- `MidletSession` has `Vm`, `Runtime`, `MainThread`, `DataRoot`, plus
  `Pause`, `Resume`, and `Stop`.
- `MidpRuntime` has `Vm`, `EventThread`, `_queue`, `_sockets`,
  `_focused`, `_multiTab`, `_tabHolding`, `HostHidden`,
  `SetFocus`, `SetHostHidden`, and `TrackSocket`/`DisconnectSockets`.
  Its metadata constant `BackgroundFps` is **10**.
- `Jvm` has `_classes`, `_threads`, `_disposables`, `FileRoot`,
  `TrackThread`, `Kill`, `DisposeTracked`.
- `OpenTab` includes a `Disconnect` option; `ProxyStore` has
  `ProxyIdForTab` and `AssignTabs`.
- `Info.plist` declares `UIBackgroundModes = audio`; the bundle includes
  an 8-second audio loop and `BackgroundAudio` playback/interruption methods.
  This is not proof that iOS lets game workers run indefinitely in background.

**Method-body limitation:** the managed MethodDef RVAs observed in the shipped
assemblies are AOT stubs at `0x2050` (a `ret`), not full C# IL. Names and
constants do **not** prove actual parallel scheduling, thread correctness,
socket longevity, memory behavior, or supported runtime capacity.

## Actionable JarBox engineering lessons

1. **One JVM per session, one focus token per screen.** Keep `MiniJVM`,
   classloader, Java threads, RMS root, runtime queues, socket ownership,
   and renderer state on an owned `JarBoxSession`; use a registry to select
   one visible token. Do not treat multiple UI tabs as proof of separate VMs.
2. **Focus is not MIDlet pause.** Parked sessions should reduce rendering
   without automatically invoking a game pause/disconnect that stops NSO
   networking. Preserve existing Deep Treo mode 8 and fallback mode 1.
3. **Render only the focused owner.** Consider frame-lock/dirty ownership
   and bounded buffers; avoid allocating three full buffers for every parked
   session or adding a fixed 10-FPS poll loop unnecessarily.
4. **Explicit socket and resource lifetimes.** Ensure stop A never disconnects
   B or releases B's native resources, even when handles or JVM pointers are
   reused. Require owner generation validation for late callbacks.
5. **Do not copy the 100-slot cap or audio loop.** Start with a hidden,
   default-off 2-JVM experiment after memory and lifetime tests. Background
   audio metadata alone is not a sustainable background-execution guarantee.

## Status and acceptance gates

JarBox currently owns the `JarBoxSession` lifecycle, worker lease and
focus-policy model, but still uses singleton `g_bridge_vm`, and
`jvm_bridge_supported_concurrent_sessions()` stays **1**. Remaining
high-risk blockers: GC/native callback lifetime, process-global Treo/Canvas
and NSO/JAR-worker state, registry/foreground routing, and device validation.

Before enabling two VMs: verify STOPPING cannot free while callbacks use a
Runtime; park A/run B, switch back with the same state, stop/restart A while
B sockets and save remain intact; stress pointer reuse, delayed UI callbacks,
RMS isolation, ASan/UBSan and TSan; finally inspect actual iPhone RAM/jetsam,
connection persistence and gameplay. Do not claim proven concurrent games
from metadata or headless host tests.
