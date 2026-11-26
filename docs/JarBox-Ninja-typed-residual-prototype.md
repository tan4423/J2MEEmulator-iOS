# Ninja wrapper typed residual prototype — offline M1/M2 bridge

Continuation of 6d7c1b1. No production runtime, JAR, build or policy change. Not a complete JVM verifier. Narrow typed IR accepts observed straight-line public final void wrappers; rejects unknown operations, mismatched local/stack integer vs reference types, out-of-range locals, branches/handlers/sync, unsupported descriptors. Reference types are coarse, not a full class-hierarchy verifier. All ordered field reads execute eagerly and are retained as values; pure loads/stores, constants and 32-bit multiplication can be evaluated lazily. Call resolution and null semantics are modeled before exact Canvas/owner/context/ABI guard. On guard miss materialize args from already read values. Never repeat field reads. This is a research executor, not a VM fast path.

## Actual test evidence
Four JARs analyzed using their original classfiles, SHA checked against prior inventory. 2000 deterministic randomized cases per wrapper in Python effect model:
| JAR | wrappers | cases | eligible headless | faults | other guard miss | eager / residual pure nodes in successful headless |
|---|---:|---:|---:|---:|---:|---:|
| Original | 7 | 14000 | 1596 | 4459 | 7945 | 31542 / 1596 |
| Nick t5 | 8 | 16000 | 1828 | 5074 | 9098 | 35950 / 1828 |
| TrungDucTV | 7 | 14000 | 1596 | 4459 | 7945 | 31542 / 1596 |
| V9 NOKEY | 8 | 16000 | 1828 | 5074 | 9098 | 35950 / 1828 |

60,000 comparisons PASS; 19,066 modeled fault cases, 34,086 other guard misses, 6,848 successful headless. 134,984 -> 6,848 pure nodes in eligible cases (-94.93%). Same IR evaluator used for eager and lazy; this does not independently prove lowering or Java semantics. Node counts exclude field reads, guards, actual rendering, dispatch overhead and all other code; not CPU benchmark.

Independent additional oracle: OpenJDK 21.0.12.1 with -Xint -Xverify:all actually executes original wrapper classes from four unchanged JARs, and separately generated residual Java compiled by javac. Instrumented Graphics and Image test doubles, not JarBox API. 1000 iterations per wrapper, same inputs, random signed 32-bit scale and args, test headless, two guard miss contexts and subclass, null receiver. Compare recorded draw arguments/exception kind and assert expected result category. 7k+8k+7k+8k = 30,000 comparisons PASS. Reflection in generated oracle preserves field access even for synthetic fields hidden from javac (TrungDucTV). This is not performance code, no true I/O, full paint, pixels, or game loop validated. No claim of real MiniJVM execution. Model resolution failures are synthetic. Actual Java oracle only tests null receiver exceptions and ordinary successful draw/no-op; no live field-race or linkage-error equivalence proof.

GitHub DNS still fails locally, real miniJVM checkout not available. The prior user's requested real MiniJVM/LCDUI differential harness remains outstanding, as does M0 dynamic paint journal. Do not promote automatic Deep Treo or treat tests as authorization. Next: real VM resolved field/call and GC/exception handling, bounded trace on actual game, identical-input differential testing and code overlay with fail-closed guards. No game tick, network, RMS, JIT, QoS or mode change.

Reproduce after generating inventory and plans with prior tools:
    python tools/ninja_residual_verify.py GAME.jar --plans /tmp/residual.json --output /tmp/model.json --trials 2000
    python tools/ninja_residual_jvm_oracle.py GAME.jar --plans /tmp/residual.json --output /tmp/oracle.json --trials 1000
Only execute locally trusted JARs in an isolated test environment. No JAR content committed.
