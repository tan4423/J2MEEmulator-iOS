# Intrinsic benchmark result and iOS compile gate

Verified exact host commit 40d572f26d344e619bf1d34cf56a828b889bb7cb, GitHub Actions run 45851661974/job 140019304761 SUCCESS. Same-mode two-MiniJVM sanitizer differential passed, Python analyzer two tests passed, O2 plain real MiniJVM benchmark all 16 legs passed. Legacy UBSan alignment/shift-base exclusions still apply. No iPhone performance or gameplay result.

| Configuration | Thread median ms | Process median ms | Paired median thread change % | Paired median process change % | Process wins |
|---|---:|---:|---:|---:|---:|
| Baseline | 52.9251 | 58.9125 | 0 | 0 | n/a |
| Array | 52.5204 | 57.8200 | -0.7320 | -1.7799 | 4/4 |
| String | 51.7001 | 57.6626 | -2.4939 | -2.1217 | 3/4 |
| Both | 51.6085 | 57.3289 | -1.3919 | -1.9753 | 4/4 |

Every candidate leg proved expected counters (array 160000, char 131008 when enabled), disabled counters zero, 16 completed worker collections, exact OpenJDK checksum. Individual combined effect not additive; four paired ratios, ~50ms thread CPU per leg, no confidence interval. Host-only mask overhead, different architecture and game call mix; do not extrapolate to device CPU or claim a breakthrough. Correctness gate passed for these workloads only. Both flags remain zero by default, no changes to interpreter or game runtime in this follow-up.

Independent GitHub macOS validation now runs the exact checked-in Codemagic script, including complete source regression suite, Java boot patches, unsigned iPhone build and matching symbols. Explicit isolated candidate override of the two flags only, rejects changed safe defaults and scrubs inherited JARBOX_* vars. A manual control build is selectable. Packaged commit and critical profile flags verified again before uploading private CI artifacts; no release or signing. Trigger only on new/changed runner/workflow or manual dispatch to limit macOS minutes. Xcode 26.3/macOS runner and full script availability are not yet verified for this workflow. Host 3 synthetic Python tests passed, not a real Xcode build. No device install until CI result is verified. Keep mode8, scoped Core, QoS and other experimental interpreter flags off. No JAR game modifications.
