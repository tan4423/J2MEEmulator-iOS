# General original-PC render island compiler

Parent abf21dc passed the shared IR real two-VM differential (B=106097 spans / 1229672 operations / 4 plans, shared A=4 B=0). Host main and iOS recipe stopped on the stale exact JIT getter count (8 instead of 7). Update the test to verify the new parked Block IR admission explicitly and count eight sites, not relax the JIT prohibition. Strict weak compatibility remains red and GC candidate off.

Render island v1 is a reusable source-work eliminator rather than a new sink configuration. It decodes complete original-PC method boundaries using the block IR decoder and searches for closed typed argument regions starting from any reference local, with a supplied symbolic void draw signature. It preserves arbitrary surrounding stack values, locals, branches, stores and calls. A region cannot read a pre-existing operand, store a local, cross a control/exception entry, contain a division, array/instance-field access, allocation, unknown effect, or branch. Integer local arithmetic and constants are removable if the entire call is certified as a no-op. Static reads are explicit per-region proof obligations, not accepted on descriptor alone. Bound code/region/stack sizes and unknown instructions fail closed. No JAR rewrite, no new render scope.

Actual runtime prototype is host-only and restricted to RenderIslandMain fixture. A plan is built once per CodeAttribute with atomic publication and freed at class destruction. Exact receiver/class, existing linked virtual target, scope closed on invoking owner, nonvolatile linked integer static reads with initialized owner and valid layout, stack capacity and suspension checks must hold before original-PC jump. The guard never resolves or initializes classes. All refused regions execute original bytecode without replay; null, cold init, volatile reads, division and visible sink effects are retained. No iOS admission, no expansion of the existing four residuals yet. This is not a general verifier or a proof of arbitrary render sink effects.

## Corpus structural reach (same C header, read-only exact SHA archive scanner)

| Family | Methods | Candidate islands | Original operations | Static read obligations |
|---|---:|---:|---:|---:|
| Nick | 66 | 302 | 3787 | 910 |
| Trung | 21 | 59 | 578 | 228 |
| V9 | 62 | 247 | 3231 | 695 |
| Original | 62 | 293 | 3708 | 902 |

Nick 269 islands / 3392 original operations in 62 methods outside k1/i3/r2/j1. These are shape candidates across all classes, not a reachable screen proof or count of dynamically avoided operations. The mod wrappers require separate exact body/effect checks (especially Trung). No authority to erase any draw solely from this result. No region found in Nick skill a0 or glyph loops; heap and exception dependencies still need proof. StringBuffer allocation remains intact.

Reproduce with python3 tools/ninja_render_island_audit.py <exact archive paths>. The mounted four JARs passed structural audit. GCC and Clang ASan/UBSan C tests passed for exact typed args, branch/handler boundaries, unknown calls, faults and truncated instructions. Two local OpenJDK -Xint processes passed the 8000-frame fixture, including visible digest, interleaved gameplay writes, cold init, volatile and null/division exceptions. The new real MiniJVM differential requires 7900–8000 omissions in the 8000 eligible closed-frame calls (allow natural cold linking and suspend refusals), at least 8 original operations per omission, refusals and GC activity. It is pending CI. Full checkout unavailable due to local DNS; no iOS device evidence or CPU claim.
