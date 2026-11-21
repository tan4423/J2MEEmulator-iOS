# Feasibility of sharing a game-aware Deep Treo mechanism across supplied JARs

Checked from the actual user-uploaded files on 2026-11-21. This is a **bytecode investigation**, not a new IPA or device result.

## What the three archives actually are

| Uploaded file | SHA-256 | Classes | Manifest entry | Role |
|---|---|---:|---|---|
| Nick-B25-Map37-Farm-Clean-CPU.jar | `7e1cff13508f0c43ad2fee30e75b38d807a1811a21fff8fbbe3ce6f70215f0a1` | 323 | `Nicknsonet`, `GameMidlet`, v1.9.30 | Ninja mod with `NickCpuSleep` |
| MicroEmulator.jar.jar | `4573c87736f2231ad01d7ca66790458ae4fc89eb38060d25d2e9e857b76b91b7` | 450 | `Main-Class: org.microemu.app.Main` | MicroEmulator desktop MIDP emulator; **not a Ninja mod** |
| Avatar258.jar | `36728fbab1bef47222002960bc26128fb9953e8b52239b0f7dc6616de95515d1` | 321 | `Avatar 258`, `main.GameMidlet`, v2.5.8 | Avatar game; **not Ninja** |

Ninja shares zero class paths with each of the other two JARs. MicroEmulator and Avatar have 104 identical **short obfuscated class filenames**, but zero byte-identical class payloads among those 104. Shared short names do not prove shared code or mod lineage.

## Bytecode observations

**Ninja:**
`NickCpuSleep.requestFrame(Class_hef)` skips `repaint()`, `flushFrame(Class_hef)` skips `serviceRepaints()`, and `NickCpuSleep.paint(Class_bs, Graphics)` skips delegating to the rendering method when its internal Treo state is active. The Ninja main game loop `Class_hxb.run()` still updates state before these rendering requests. This supports an exact-version early-presentation bypass candidate. Whether it preserves game progress over long AFK sessions still requires device testing.

**Avatar:**
`main.a` is a `Canvas` implementing `Runnable`. In `main.a.run()`, after the game work the method calls `Canvas.repaint()`, then conditionally `Object.wait(1000)` under monitor `main.a.an` when static flag `E` is set, otherwise `Canvas.serviceRepaints()`. In `main.a.paint(Graphics)`, if `E` is set, the method locks that **same monitor** and calls `Object.notify()`. Thus completely suppressing Avatar's `paint()` can change tick pacing and wake behavior. The 1000ms wait times out eventually, so it is not proof of a permanent deadlock, but it is clear behavioral risk. Do not apply Ninja's paint elision unchanged.

**MicroEmulator:**
A Java ME runtime, not a game JAR. Its `org.microemu.app.Main` is a desktop emulator entrypoint, not a MIDlet simulation/render loop.

## What CAN be common

1. **Structural profile discovery:** Identify game MIDlet/Canvas implementation, Runnable loops, update and present call sites, ownership of repaint/flush, and per-version opcode fingerprints. Do not rely on class names or JAR titles alone.
2. **Side-effect and synchronization analysis:** Model writes, heap allocations, native methods, I/O, clocks, game state, monitor enter/exit, `wait/notify`, and calls reachable from `paint`. Reject early Java paint elision when unresolved effects matter to simulation.
3. **Verified game-family recipes:** Match exact bytecode fingerprints and apply a rule for a family of mods when their critical simulation/presentation methods are *equivalent*. Rules may choose: skip before `paint` for verified Ninja; preserve or emulate a verified Avatar wake signal while avoiding the render subtree; otherwise fallback to universal Treo.
4. **Differential safety gates:** Verify real tick progression, network/auto, correct state/persistence, wake redraw/input, GC/heap and CPU in matched iPhone runs. Keep an easy rollback and never silently promote based solely on structural guesses.

An exact full-JAR SHA gate in the current Ninja Deep Treo proof of concept is deliberately restrictive. It can later be replaced with family fingerprints of only the relevant bytecode methods, combined with safety/correctness probes, once *actual different Ninja variants* are provided and compared. Unrelated JARs should not inherit Ninja's skip.

## Operational constraints

Do not add Codemagic workflows. Continue using **only** `J2ME Treo JIT probe unsigned` on branch `loader-ios-jit-probe`. Do not modify `main` or game JARs. No new generalized runtime skip should be activated based on the three files above. Future user uploads of two Ninja mods and one unmodified Ninja are required to evaluate Ninja-version compatibility specifically.
