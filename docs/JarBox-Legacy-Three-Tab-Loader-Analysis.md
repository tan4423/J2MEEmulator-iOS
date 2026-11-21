# Legacy 3-tab Java ME loader — static reference audit

Date: 2026-11-22
Reference supplied by user: `Nicknsonet_t5_x3.jar`
SHA-256: `39fc669dd914c48866b27024f3a1b6ceccfa33d1258e2d3c3b4ae6c71347a91e`
**Reference file is NOT copied, imported or added to the JarBox source tree.**
Static ZIP / classfile / `javap -p -c` inspection only; the MIDlet was never executed.

## What this JAR actually contains

Manifest entry point:

```text
MIDlet-1: Nicknsonet,/MrQuyet/mid.png,MrQuyet.MrQuyet
0: Nicknsonet 1,/MrQuyet/mid.png,GameMidlet,/tab0.ini
1: Nicknsonet 2,/MrQuyet/mid.png,b.GameMidlet,/tab1.ini
2: Nicknsonet 3,/MrQuyet/mid.png,c.GameMidlet,/tab2.ini
```

The JAR has 1,255 ZIP entries and **910 classfiles**:
297 root-level game classes, the **same 297 class basenames**
in `b/`, and the same 297 in `c/`; plus 17 `lib/` classes
and 2 `MrQuyet/` classes. The bytecode distribution is
906 major-47 (Java 1.3) and four 45.3 (Java 1.1) classfiles.
The 345 non-class entries include `x1/`, `map/`, `font/`,
three **empty** `tabN.ini` files and launcher icons. The game
resources are generally **shared** across clones, not copied into
three separate resource trees.

**This is a class-namespace duplication/multi-MIDlet technique in one
Java ME process/VM, not evidence of three isolated Java virtual machines.**
Each copy's original static class fields receive distinct class names
(e.g. `GameMidlet`, `b.GameMidlet`, `c.GameMidlet`), but shared
helper libraries still hold process/VM-wide static state.

## Mechanics confirmed in the actual bytecode

1. **Loader, not a separate emulator.** `MrQuyet.MrQuyet`
   extends `javax.microedition.midlet.MIDlet`, implements
   `Runnable` and `CommandListener`, and is the manifest's only
   normal `MIDlet-1` entry.
2. **Tab registry and lazy start.** It reads manifest properties
   named `0`, `1`, `2` through `getAppProperty`, creates
   `MidletInfo` entries and a `lib.MIDlet[]` array.
   In its `commandAction`, selecting an already-created element
   calls `lib.MIDlet.showDisplay()`; otherwise it starts a
   `Thread(Runnable)`. `run()` reflectively constructs the
   requested game by `MidletInfo.newInstance`, records the instance
   in that array and calls `lib.MIDlet.start()`. Thus returning to
   the first tab **does not require reconstructing its Java game**.
3. **One visible MIDP display.** `lib.Display` keeps a
   `Hashtable<lib.MIDlet, lib.Display>`, and each wrapper stores
   its own last `Displayable`. But all wrappers call the same
   static `javax.microedition.lcdui.Display d` for actual output.
   This is screen swapping, **not isolated display/render state**.
4. **RMS namespace rewriting.** `lib.RecordStore` wraps the
   platform's `javax.microedition.rms.RecordStore`, prefixing
   a different character before the caller's store name. Root game
   class references call `apenRecordStore` (prefix `a`);
   `b/` calls `bpenRecordStore` (prefix `b`); `c/` calls
   `cpenRecordStore` (prefix `c`). This achieves a partial
   separation *inside the same RMS filesystem namespace*.
   It is weaker than separate save directories by clone UUID.
5. **Reflection and IO shims.** `lib.Class.load(prefix,name)`
   tries `Class.forName(prefix+name)`, then the unprefixed
   name. `lib.Connector` delegates to J2ME Connector but has a
   static `UrlMap` hash table for URL substitutions.
   These are packaging shims, not a safe model for JarBox-native
   per-session socket ownership.
6. **Independent stop button in the loader.** Selecting stop
   calls `lib.MIDlet.notifyDestroyed()` on the selected instance,
   and `MrQuyet.destroy` removes its `lib.Display` map entry,
   clears the corresponding MIDlet array slot, updates the icon
   and requests `System.gc()`. Other entries remain in the array.
   A separate loader command can destroy all entries.
7. **Global helper-state limits.** `lib.MIDlet.nowmf` and
   `lib.MIDlet.mid`, `lib.Display.d` and `lib.Display.mc`,
   `lib.Connector.UrlMap`, `lib.Canvas.image/buff`, and the
   `lib.GameCanvas` shared image are Java statics across the
   three copies. `lib.GameCanvas.getKeyStates()` simply returns
   zero. These are compatibility compromises and potential
   cross-instance interference, **not patterns to port**.

`tab0.ini`, `tab1.ini`, and `tab2.ini` are zero-byte placeholders.
No evidence was found that they are copies of game save records.
The loader also contains an on-device RMS backup/export routine
using `FileConnection`, but that routine is not a guarantee of
atomic snapshots or independent filesystem ownership.

## What to adopt in JarBox, and what NOT to adopt

| Legacy pattern | JarBox-compatible successor |
| --- | --- |
| One loader shows a list of three games | One JAR icon expands original and clone UUID tabs |
| Lazy-create tab, retain object array | Create a genuine independent miniJVM heap + classloader for each tab |
| Re-select tab restores its last Displayable | Focus switch routes correct owned MIDP screen/Canvas callbacks and input |
| Stop selected MIDlet, leave others | Token-scoped VM shutdown; release only that instance's network/audio/RMS/GPU/GC |
| Rewritten RMS name `a/b/c` | Separate `app.save.root` folder for every clone UUID |
| Three physically duplicated class trees | Share immutable JAR bytes, create separately owned VM class definitions |
| Shared `Display.d`, `Canvas.image`, `UrlMap` | No mutable per-game state without an explicit owner token |
| Background tabs still have Java logic | Automatic offscreen Treo + verified headless safety; preserve game/network clocks |
| Static global launcher current-index | Stable group ID + instance UUID + native VM generation, never filename alone |

This reference **supports the UX and lifecycle goal**, not the safety claim
that Java class renaming would equal full VM isolation. Avoid transplanting
its runtime shims into JarBox.

## Multi-JVM acceptance tests derived from the loader

- Start original + clone A + clone B of *one JAR* and switch focus 100
  times; each tab returns to its exact prior MIDP screen and account
  without rebuilding the MIDlet.
- Keep A and C online while B is stopped. Confirm B's RMS, player
  callbacks, VM threads, network sockets, native images, GC and
  framebuffer are cleaned without touching A or C.
- Create clones with factory-default RMS; verify no original password,
  character settings, logs, static fields or file handles are reused.
- Trigger a delayed audio completion, network callback and MIDP Alert
  from B while A is displayed; none may appear in A.
- With multiple parked games, record whole-process CPU, memory and
  thermal pressure over several minutes; don't promise all games
  use 2% CPU just because one legacy Avatar Treo benchmark did.
- Kill/restart JarBox and check every instance's persisted clone UUID
  resolves to **only its own save directory**. A dead JVM must never be
  shown as live merely because its clone tab still exists.
- Keep the exclusive VM gate until renderer, graphics handles, native
  heap/GC, Treo mode, MIDP UI, 3D, JIT and network callback ownership
  have passed dedicated runtime/device concurrency tests.

The existing JarBox per-tab default-RMS model is therefore *stronger*
than this old JAR's `a/b/c` RecordStore-name prefixes. The current
`loader-ios-jit-probe` native bridge has not yet achieved complete
2+ JVM isolation; this file is reference analysis, not a build pass.
