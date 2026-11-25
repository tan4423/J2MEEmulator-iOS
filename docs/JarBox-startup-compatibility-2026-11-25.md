# Startup compatibility: NST V9 X1 and TrungDucTV

2026-11-25 — source-level fix, device verification pending.

Two unmodified supplied archives pass ZIP CRC validation:
- V9_X1_NOKEY.jar: 632 entries, 291 classes, 130 distinct pairs of class
  entry names differing only in case (260 classes). Example a.class/A.class:
  1,169 and 1,430 bytes, respectively. CLDC 1.1 / MIDP 2.0.
- 217_TrungDucTV_51026.jar: 521 entries, 184 classes; no case collisions.
  CLDC 1.0 / MIDP 2.0.

The old miniz wrapper used a case-insensitive lookup, even for class files.
It could return the wrong class bytes, and size and extract paths could
select different entries. Fix all four read-only lookup paths to use
case-sensitive names, and extract by the resolved index. Skip the unused
case-folded central directory sort on each read-only open. Reject sizes
that cannot fit a Java byte array/ByteBuf, and verify capacity after
ByteBuf expansion before extraction. Writer paths are unchanged.
No user JARs are stored or modified by this change.

This is a concrete correctness bug, but not proof of the exact native
crash stack on iOS. The startup speed gain is not measured on device.
The TrungDucTV old-version dialog is not explained by the case collisions;
do not suppress the dialog, alter game version fields or fake server
responses. Capture runtime exception/network diagnostics if it persists.
Compare cold launch with identical JARs on the same device, and preserve
existing RMS. If NST still terminates the iOS process, collect the
matching .ips or JetsamEvent report. No JIT, background modes, session
caps, rendering or network protocol changes in this patch.
