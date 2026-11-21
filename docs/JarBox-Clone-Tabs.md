# JarBox clone tabs — grouped installs with independent data

Status: **clone UI + private-data routing implemented in source, not yet IPA-tested.**
Branch: `loader-ios-jit-probe`. Original single-live-JVM safety gate remains enforced.

## User model

A single game icon represents **one group** of tabs. The group is keyed
to the exact imported JAR filename (SHA-256), not the user-visible alias.
With no clones, tapping the icon opens the original as before.
Once clones exist, tapping the icon expands an action list:

- **Tab gốc**: original game's existing RMS and existing configuration.
- **Tab 1, Tab 2, ...**: independently identified clones. A dot appears next
  to the *exact* tab that owns the currently parked JVM.
- **+ Tab**: creates the next default clone with a new UUID and an empty,
  private game save directory. It **never copies the original's account,
  RMS records, cache, logs, or user-edited resolution/FPS/3D settings**.
  The clone refers to the same immutable JAR bytes, not a mutable shared
  Java heap. The MIDlet creates its default RMS data on its first launch.
- **− Tab**: choose an individual clone, then confirm. Its own RMS, logs,
  files and clone-specific UserDefaults keys are deleted. Other clones
  and Tab gốc are unaffected. The original cannot be removed by − Tab.

Long-press the group icon also exposes **+ Tab**, **− Tab**, and game
information. The group chooser has an **Thông tin các tab** picker; each
individual tab's information exposes its own **Nhật ký save**.

The backend keys each clone by a freshly generated **UUID**; the label
“Tab 1” is presentation metadata only. Removing and re-adding Tab 1 gets
a different UUID and **does not reuse the deleted account/save**.

## Physical separation

- Group binary: `Documents/games/Avatar.jar` (example; not duplicated).
- Original save: `Documents/Games Data/inst-<SHA256(filename)>`.
- Clone save: `Documents/Games Data/inst-<SHA256(filename)>-clone-<UUID>`.
- Original prefs: `fpsLimit_<SHA256>` and other per-game keys.
- Clone prefs: `fpsLimit_<SHA256>_clone_<UUID>` and equivalents.
- Each instance has separate `rms-events.log` (RMS native-backed Java
  events) and `settings-events.log` (Swift settings/lifecycle events).
  An on-demand viewer merges the latest records. No RMS payloads, account
  details, original store names, or packet contents are intentionally logged.
  The two writer logs are separated to avoid cross-thread seek/write races.

The actual Java `System` property `app.save.root` is provided through
`sys_properties_set_c(vm, ...)`, so `AndroidRecordStoreManager` resolves
the selected instance's private root. The JVM launch carries the clone's
UUID all the way from the selected group option to `runMIDlet`, not just
to a cosmetic label. The same Java JAR can therefore be run separately
with default data as the old JVM exits and a new one starts.

Clone registry: `Documents/Game Instances/<SHA256(filename)>.json`.
The registry is protected by a lock and written atomically.
Deletion stages only the selected private directory under a temporary
tombstone name and attempts rollback on failure. Existing original saves
are never used as clone data. Legacy original RMS is migrated only when
its sanitized filename has exactly one owner.

**Do not change or remove the group JAR without managing its clones.**
Replacing an imported JAR with active clones is blocked. Removing the
original JAR is blocked until all clones have been individually deleted.
Failed JAR imports use a staging file rather than first deleting the
working binary.

## Runtime limits (not equivalent to native multi-JVM)

The clone **data model** is independent, and each tab has its own identity
suitable for future multi-JVM ownership. But the current native renderer,
MIDP Form/List/Alert bridge, Treo/GC and 3D still contain process globals.
Therefore the existing one-JVM acquisition guard remains intact.
A user can run Tab gốc, stop it, then run Tab 1 with separate data; **two
tabs cannot yet execute Java simultaneously**. The UI must not fake it.

Deletion of a clone still requires *all* JVMs to be stopped, conservatively,
until per-instance filesystem leases and native shutdown are complete.
Creating a new default tab is metadata-only and does not need to copy
or read a running JVM's save. Future multi-session work must preserve:
instance UUID → VM owner token → per-VM save/IO/render/audio/Treo state,
and only permit removing a tab after its exact JVM and file handles stop.

## Verification

`tools/tests/test_clone_instance_storage.py` extracts the real Swift
storage enum, compiles it using macOS Swift/CryptoKit, and exercises:
fresh empty clone roots, independent UUID and settings keys, unchanged
original saves, independent accounts, blocked deletion during an active
native slot, removal of one clone without touching others, no reuse of
deleted tab identity, and group registry persistence. The test skips
on platforms lacking Swift/CryptoKit; test discovery in the existing
Codemagic workflow includes it.

`tools/tests/test_rms_persistence_audit.py` compiles the RMS Java sources
and tests independent save directories, metadata logs and preservation
of broken on-disk RMS bytes. Native iPhone startup and a 2+ JVM stress
test remain outstanding. Never label clone UI completion as full
multi-JVM runtime completion.
