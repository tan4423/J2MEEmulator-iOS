# JarBox PC — Research Lab (WSL/Linux preview)

This is an isolated Linux/WSL prototype using the repository's real MiniJVM,
Java LCDUI and MIDletRunner. No game archives are included. It is a Windows/WSL launcher bundle, **not** a native Windows executable or a validated Nick gameplay environment yet.
The iOS renderer is not replaced. No deep mode is enabled, and the host-only
method entry hook is compiled out of all existing production builds.

## Build and run

On Ubuntu 24.04/WSL2 with WSLg: install gcc, pkg-config, OpenJDK 17, libsdl2-dev,
libcairo2-dev, python3 and git. From the repo root:
    
    bash tools/desktop_lab/build.sh
    bash tools/desktop_lab/test.sh build/desktop-lab

For a local copy of a game (never commit it), use absolute paths without colon
characters, create a new private save directory and run:

    build/desktop-lab/jarbox-lab \
      "$PWD/build/desktop-lab/jars/minijvm_rt.jar" \
      "$PWD/build/desktop-lab/jars/j2me_api.jar" \
      /absolute/path/game.jar /absolute/path/isolated-save \
      /absolute/path/trace.csv 240 320 graph

Arrow keys, Enter, F1/F2 and digits map to Canvas key codes. Escape or closing
the window asks the original MIDletRunner/Display to stop. If a game is stuck
in startup, terminate the isolated process rather than freeing a live VM.

Plain mode disables the method graph; graph mode records bounded dynamic
caller/callee counts at execute_method_impl entry (inlined calls not counted).
No arguments, strings, login data or packet bytes in the CSV or edge table.
Do not publish raw JVM stdout: the game itself may print sensitive data.
CPU is cumulative process time, including SDL and the observer; compare
matched plain-mode windows, never use graph-mode CPU as release evidence.
GC cycles and CPU are sampled live under the VM lifecycle lock. The call graph is exported atomically every five seconds. Run `python3 tools/desktop_lab/inspect.py /absolute/path/trace.csv --watch` for rolling CPU and graph summaries. Surface and trace storage are bounded
except the one-row-per-second CSV written until stop.

## Known limitations and next gates

- Linux SDL/Cairo 2D renderer, not CoreGraphics/Metal. Font metrics and pixels
  may differ. PNG only. Basic native Form/TextBox/List/Alert is implemented for lab use, with Tab/arrows, typing and F1/F2/Enter; list icons and full MIDP constraints/choice labels are not equivalent yet. No audio, 3D,
  or 3D parity. SDL pointer input and the repository TLS implementation are included; desktop TLS requires valid peer certificates (the existing iOS optional-auth policy is unchanged). The unsupported paths
  must not be treated as successful game behavior. This is a Canvas fixture
  milestone, not evidence that Nick can log in.
- One VM per process, no reuse of numeric native surface handles. Surface slots are recycled using generation-tagged handles, so stale Java handles cannot alias new images.
- Runtime patching reuses the exact iOS Java patch block on copied boot/API
  JARs. The lab uses a game-facing iOS profile and the same 500ms GC settings.
- Next: validate full UI/input, image and font parity, live transport/TLS, run
  Nick with an isolated save, verify startup and genuine state progression;
  then add targeted field/effect tracing and replay with separate reference
  and candidate VMs. Do not use a live server as a differential test harness.
- Existing CI/device checkpoints remain authoritative. Desktop speed is not
  iPhone CPU evidence; no production admission of any new Deep Treo path.

Graph mode now records linked Class_hda.s6:I int reads/writes at original
interpreter field operations, with worker, method, converted PC, value and
monotonic timestamp. It uses the value already loaded/stored by MiniJVM.
No additional heap read, no object identity, no credentials. The special
LabFixture$Probe field serves as an executable positive gate. The bounded
4096-event ring reports loss if export cannot keep up. Converted PCs and
role labels still need exact archive verification; no authorization to
remove effects follows from the trace. The SDL dummy test drives a real
TextBox command via SDL input events before the Canvas pixel test.

## Windows bundle

Download the successful `JarBox-PC-WSL-x64` artifact from GitHub Actions,
extract it to a folder, and double-click Start-JarBox.cmd. Requires x64
Windows with WSL2/WSLg Ubuntu-24.04; the launcher prints the one-time WSL
install command if needed. It prompts before installing Linux packages.
The launcher verifies bundle hashes, offers JAR selection, separate graph/plain
runs, live metrics, persistent per-archive isolated RMS, and clean ZIP export.
No game archives or credentials are included. Game close is cooperative; if
startup hangs, terminate the isolated process (not an in-process VM free).
The fixture uses actual MiniJVM, real TCP to a loopback-only peer, RMS
close/reopen, modal text input, offscreen pixel reads and shape drawing.
It never connects to a game server. The new GUI and WSL installation still
need a Windows-device test. Deep Treo remains disabled until its shared
runtime admission contract is ported and validated.

Nick t5 archive SHA-256 11b1d4c11f9082b9d07bc7bd92a9ad3abad40764853e23686cc86686869c966c was inspected locally: 168 PNG assets, 20 taller than 2048, maximum 24x3432. The desktop decoder now accepts bounded images up to 8192 per axis and 16M pixels, independent of the screen limit; CI decodes a generated 24x3432 atlas and tests its last pixel and a lower tile. No original game asset is committed or used by CI.

Local real-game offline gate at 5f1497b: original Nick t5 opened the game
menu and account editor under X11/SDL (240x320), received actual pointer
and keyboard events, and exited with rc=0 and no input overflow. Network
sockets were denied by seccomp, so this is not an online gameplay gate.
99 images allocated during startup; no image decode refusal. The initial
desktop GC telemetry was found to be zero despite actual collector logs
because iOS-only counters were not active. The lab now records real
collector attempts, aborts, thread CPU and published heap samples under a
desktop-only flag; CI requires positive values. No GC policy is changed.


## JarBox PC settings

Use the Settings button in the launcher to persist:
- Default JAR path (no account credentials are stored).
- Game viewport width and height (64–2048; Nick baseline 240x320).
- Default trace mode: graph/effects or plain CPU baseline.
- Research data/RMS root (private local directory).
- Live metrics refresh interval (500/1000/2000/5000 ms).

Settings are stored in the user's config directory with owner-only permissions
and atomically replaced. Session data lives under the selected research root.
The dialog refuses to change that root while a game is running. The existing
main-window resolution and trace controls remain quick overrides; the current
values are persisted when a session starts.

The game-facing iOS compatibility profile, 128 MiB VM heap, 500 ms collector
period and 70% heap trigger are deliberately fixed and shown read-only. They
are not exposed as tuning controls because changing them could alter gameplay
timing and invalidate comparisons. Credentials and raw login data are never
written into settings or exported research ZIPs.

## Logic-only experimental profile (developer CLI)

The desktop executable accepts a third mode, `logic`, alongside `plain`
and `graph`. It uses the existing shared MiniJVM Block IR engine for pure
arithmetic/local spans, with original effect/branch handlers intact. Full
paint, input, network, GC and RMS paths remain enabled. It requires exact Nick
t5 SHA-256, except the isolated dummy-display test fixture. It is not headless,
not an iPhone performance claim, and not selectable in the normal GUI yet.
Use separate save roots for tests; do not launch a second live session with
the same account. Compare plain versus logic with graph disabled in both.
On orderly exit LAB_LOGIC reports actual plans, spans and operations. These
counters indicate admission, not CPU savings. The desktop A/B fixture must
pass arithmetic, TCP/RMS, UI and pixel checks with positive B admission and
zero A admission. The current live game is not interrupted by this change.

## Background research input
The graph-mode launcher opts into a private per-session Unix datagram socket
`control.sock`; CLI users may set JARBOX_LAB_CONTROL=1 in a private session.
No TCP listener, Windows cursor, foreground focus, shell execution or text
entry is used. `python3 labctl.py SESSION status|snapshot|stop`,
`... SESSION tap X Y` (logical Canvas coordinates), and
`... SESSION key enter|up|down|left|right|f1|f2|f3|0..9` are supported.
Snapshot writes control-frame.png locally, never in automatic exports;
it may show private information. Keep it local, inspect before sharing.
A queued response is not proof that a game action completed. Verify screen
and state transitions, allowing for login/load delays. Control is separate
from gameplay timing and is never enabled in default plain CPU baselines.

For the exact research workflow, `labctl.py SESSION chat gm37|k27|ts`
only fills an empty non-password TextBox titled `chat`. Use `key f1`
separately to submit, then verify the map and zone. Other strings are refused.

## Experimental scoped screen raster sink
`labctl.py SESSION sink on|off` toggles the desktop-only experiment for the exact Nick archive, default off. It reuses Canvas Core full-repaint checks, keeps Java paint and offscreen Image raster, and discards only native screen draw calls within the same thread/context. Trace includes actual admissions, discarded operations and invalidation. Screen input refused while the framebuffer is stale; restore sink off before using input. A pixel dependency or failed paint invalidates the experiment. Fixture A/B/A asserts paint progression, offscreen pixels, no presented frames during B and restored frames on exit. This is a lab candidate, not a claim of gameplay equivalence or iOS savings.

Desktop `sink deep` adds exact bundled Graphics leaf elision; `sink glyph` also ports the audited Nick glyph loop preflight and reference-lane replay, scoped to an actual screen Canvas. Both require exact game and build-generated boot/API identities. New trace counters report actual admissions and refusals. Experimental, default off; live performance and equivalence must be measured.

`sink map` extends glyph mode with exact Class_hii q3/m3 successful array reads on the paint worker. Original exceptions, cold linkage, other threads and other JARs fall back. Map counters record both primitive kinds and refusals. No live map data cached.

`sink ir` adds the existing Block IR pure integer spans on the scoped paint worker (not the other simulation/network threads). `profile counters` / `profile graph` pause/resume only the expensive call graph in a research session. Skill effect trace stays active; trace `graph_enabled` distinguishes the phases. Counter-only is not the same as an uninstrumented production CPU benchmark. IR counters identify real execution.


`sink residual` (level 6) is an isolated desktop trial of the existing exact Nick k1/i3/r2/j1 residual compiler and original-PC effect executor, layered on Map without Block IR. It shares the compiler and linked wrapper proof rather than using the offline map snapshot kernel on live data. The native owner-local paint lease and exact archive/API/boot gates are required, with frame-local Canvas/Graphics binding and checkpoint validation. All retained reads, writes, calls and faults follow the original interpreter. Cold or unsupported plans fall back; a changed scope resumes before the next draw region, without replay. Invariant faults invalidate the sample and unwind, never retry a partial frame. No production flag change. The four residual counters distinguish publication, admission, regions and continuations. Fixture control rejects this real-game tier; existing two-VM host differential tests remain the executor oracle. Live admission and CPU benefit must be checked separately.


Map lookup now publishes only immutable, naturally linked static-field offsets in each owning CodeAttribute. The original array reference, width, bounds, exception fallback and reference-lane writes remain live on every invocation. Cold linkage is not cached as a permanent refusal. Per-paint diagnostic counters batch until paired paint end (sampling may lag one paint); fixture checks require both offset plans and actual reuse while retaining the exact success/refusal counts. No iOS runtime policy changes.


Counter-only graph-launch sessions retain passive skill-advance, network-call and update-call counts for research. Quiet gameplay, idle paint, disconnect, maintenance and modal UI are not proof of a runtime fault and never cancel the requested sink. No time-based admission gate or watchdog action. Exact archive/API identity, owner/Canvas/Graphics scope, cold-link and original-PC fallbacks remain; concrete residual invariant failures, screen pixel dependencies and failed Core paint still invalidate the experiment. UI continues through the separate native modal path. Explicit sink off restores raster; a completed visible paint is the recovery evidence. A fixture waits nine seconds with no game liveness signals and verifies that the selected sink remains active, then restores pixels and verifies ordinary input. No iOS policy change.

The normal desktop launcher enforces a 31-second relaunch interval per save root after it observes a completed child exit. The marker is held and written under the existing save flock; another save is independent. A normal launcher close also reaps and records the exit. Raw binary invocation, abnormal launcher loss and in-game logout/reconnect are not covered by this launcher rule. OneFlow restart procedures must separately wait at least 31 seconds after confirming old process termination. No sleeping or timer in the running game.
