# Focused Treo device result (2026-11-26)
Build 5e8bc1d860fcff786bebd1a3611e6f667f3dece7, Codemagic focused workflow SUCCESS, iPhone11,6 iOS18.6.2, run 18A252F8-D1F2-4C36-A215-B661D2A7F982. Original strict ABA analyzer passed. Sequence 1–65 contiguous, no write failures, one owner 1, profile2, core epoch 713147567984250, no thermal/memory/low-power warnings. High-frequency native, region and hotspot probes off; GC and Canvas phases on. Both intrinsic and binary raster flags OFF. Stable legs ~55s each, seq14–25,29–40,44–55.

| Metric | A1 | B | A2 |
|---|---:|---:|---:|
| Process CPU % | 42.18774 | 44.30078 | 42.03676 |
| Paint CPU % | 33.60473 | 24.80097 | 33.82012 |
| Java minus paint % (arithmetic) | 6.78973 | 14.62740 | 6.48854 |
| GC worker CPU % | 1.47620 | 4.33167 | 1.44216 |
| GC cycles | 113 | 110 | 112 |
| GC worker CPU ms/cycle | 7.18581 | 21.66058 | 7.08278 |
| Scanned objects/cycle | 77111.73 | 80257.03 | 77937.14 |
| Reclaimed objects/cycle | 5501.66 | 6803.34 | 4160.50 |
| Freed bytes/cycle | 526854.96 | 674224.59 | 367235.88 |
| Mark CPU ms/cycle | 4.29488 | 13.60642 | 4.16718 |
| Deferred CPU ms/cycle | 1.39311 | 4.64252 | 1.42384 |
| Sweep CPU ms/cycle | 1.33058 | 3.08341 | 1.32825 |
| Canvas pre CPU % | .08743 | .15969 | .07442 |
| Canvas post CPU % | .00902 | .03302 | .00847 |
| Paint Hz | 25.54281 | 25.37918 | 25.61549 |

GC/Canvas phase snapshots OK, zero invalid/busy/abort deltas, exact cycle/frame coverage, sum of GC phases differs from worker total by only 0.01766/0.02849/0.01674 points. B 1396 Core frames and 1,509,174 scoped skips; zero faults/rejects, no whole-paint/repaint/service skips. B vs mean A process +2.18852 points, paint -8.91145, Java-minus-paint +7.98827, GC +2.87249, runner +.17662, residual +.06260. A2 drift -.15098. Mark accounts for ~1.86 of the 2.87 GC points. Work volume scanned grows ~3.5%, not enough to explain 3.04x CPU/cycle. Reclamation volume rises too, but CPU residency/frequency/cache/scene and allocation changes not determined. GC phase times CPU not wall; nearly equal except pause. Canvas wrapper tiny. Arithmetic Java-minus-paint is not direct measurement of game logic. Second controlled rejection of scoped sink even without high-frequency probes; do not promote or repeat identical diagnostic. Normal full raster default retained. Seq60 park exit, seq61 active mode, seq62 park again, seq65 export. Actual XP/combat/network progression unconfirmed. No new device test requested.

# Implemented follow-up
Optimize actual GC hot scan: keep null/already-marked reference checks inline at each traversal edge; only newly discovered objects dispatch DFS. Same mark tag, order, weak edge exclusions, class/loader links, debug counting and public entry. Primitive-array reference-type check uses exact two constants from jvm_util.c, no function call. Deferred traversal checks mark/finalized flags before touching class metadata; callback order, STOP checks, remark and sweep unchanged. No change in GC interval/heap/Java/tick/JAR or scoped Core. Updated existing extraction oracle across all 255 nonzero tag values and both reference array kinds, retains independent old graph walk and finalizer/weak checks. Linux CI runs extraction fixtures with sanitizers plus existing integrated two-VM workload. No local full source checkout, no new CI or measured savings yet. GC alone cannot bridge 42% to <10%; continue prioritizing effect-preserving elimination of proven render-only work and validated raster fallback.
