# JarBox Research Lab v0 — desktop execution substrate

This is an isolated Linux/WSL prototype using the repository's real MiniJVM,
Java LCDUI and MIDletRunner. No game archives are included. It is **not** a
Windows native executable or a validated Nick gameplay environment yet.
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
  pointer handling, or TLS (existing host SSL stubs). The unsupported paths
  must not be treated as successful game behavior. This is a Canvas fixture
  milestone, not evidence that Nick can log in.
- One VM per process, no reuse of numeric native surface handles. The finite
  handle budget is deliberately conservative for this first fixture.
- Runtime patching reuses the exact iOS Java patch block on copied boot/API
  JARs. The lab uses a game-facing iOS profile and the same 500ms GC settings.
- Next: validate UI/input, image and font parity, real transport/TLS, run
  Nick with an isolated save, verify startup and genuine state progression;
  then add targeted field/effect tracing and replay with separate reference
  and candidate VMs. Do not use a live server as a differential test harness.
- Existing CI/device checkpoints remain authoritative. Desktop speed is not
  iPhone CPU evidence; no production admission of any new Deep Treo path.
