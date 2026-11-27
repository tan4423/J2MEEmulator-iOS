# Nick t5 map whole-method effect projection

Exact archive SHA-256: 11b1d4c11f9082b9d07bc7bd92a9ad3abad40764853e23686cc86686869c966c.
The game is unchanged. This is an offline kernel, not a live runtime admission.

## Game-level audit

3,429 methods with Code scanned. Class_hii.k1(LClass_hvi;)V has 751 instructions (1,368 bytes), 44 calls (21 draw calls and 23 q3/m3 calls), and four putstatic sites. The four private scratch fields a2/b2/d2/c2 have exactly six direct accesses across the archive, all in k1 (PCs 1171,1178,1186,1195,1202,1220). No direct reflection field calls found by the scan; this is not a universal alias or dynamic loading proof.

The built-in toiUuDoHoa setting has map/minimap routes (Class_hmi.m/k) but also character rendering routes n/p and other actor routes. Do not toggle it globally or suppress paint: Class_hda.a0 has 1,225 instructions and 76 writes/monitor operations including skill progress at PC1424. Class_hac.a0 has 3,870 instructions and 650 calls including text construction; Class_hhb.a has 141 instructions, six calls, no writes or monitor operations; classify those independently.

## New kernel

jnm_project reduces the tile loop to branch classification and the four original write values in order. It uses Java wrapping int arithmetic, bounded dimensions, and refuses any attempted invalid array access (including caught q3/m3 faults) or zero divisor without modifying output. All inputs are offline immutable snapshots. The result is final fields, count and order-sensitive digest, NOT permission to batch or drop actual Java field writes.

Run locally with the user's archive, not distributed with the repo:

    python3 tools/ninja_nick_map_effect.py /path/to/Nicknsonet_t5.jar

The oracle executes original k1/q3/m3 Code in isolated OpenJDK -Xint fixtures, with field-write trace instrumentation and no-op drawing stubs. It preserves the archive on disk. Seed 77123, 12,000 cases: 6,469 accepted, 5,531 refused, 4,370 original exceptions, 3,164 accepted nonempty write cases and 67,276 matched write events (count and digest plus final values); no accepted mismatch and no refusal mutates result. This is not full-game or concurrency equivalence and not a CPU benchmark.

## Next admission gate

Need real MiniJVM fixture with linked fields, class-init and exact method/CP identity, live ordered writes and original-PC fallback, safepoints and scratch-lane comparison, and screen-only scope validation. Do not execute the whole-method kernel on mutable live arrays as if immutable. Preserve all unknown effects and exceptions; do not toggle game RMS or alter game cadence. No iOS runtime integration in this commit.
