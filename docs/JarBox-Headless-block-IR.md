# Headless execution engine: original-PC block IR v1

This is a generic semantic execution substrate, not another Nick method-specific intrinsic and not a new render-sink trial. It lowers whole-method straight-line local/stack regions into immutable entry-relative slots. The compiler parses instruction widths, wide operands, tableswitch/lookupswitch and branch/exception-handler boundaries. Unsupported instructions stay in the ordinary interpreter; malformed boundaries or bounded compilation failure reject the plan. JSR/RET are deliberately unsupported. A span contains 4–32 original operations. Arithmetic uses exact Java integer helpers, including long shifts and conversions; references and integer/long bit lanes are copied exactly as the original MiniJVM (including stale reference lanes). All calls, heap/array/static accesses, allocation, monitor operations, division/remainder, control transfers and faults are original handlers. No heap effects are removed, no branch/backedge is bypassed, no exception table is rewritten. This is not a whole-method JVM verifier.

The runtime admits only the host BlockMain fixture in an explicit test build, with per-owner enable set before init, no JDWP/STOP/suspend admission, original stack capacity checked at each span, no residual-frame overlap. One atomic publication per CodeAttribute, losers interpret, 1 MiB per-VM lifetime publication budget, no class/heap pointers in tape, free at code destruction. Generic engine compiled into interpreter but production admission deliberately absent. No new device configuration or CPU claim. The pointer-free tape is suitable for future exact-byte immutable sharing; this batch does not share live plans between JVMs. Future effect-certified render slicing can use these same original-PC boundaries without treating any unresolved memory/call effect as pure.

## Actual corpus coverage (raw classfile Code, same C compiler, 4 mounted exact archives)

| Family | Code methods | Methods with spans | Spans | Lowered operations | Plan bytes if all published |
|---|---:|---:|---:|---:|---:|
| Nick t5 11b1d4c11f90 | 3429 | 629 | 2701 | 14071 | 222132 |
| Trung 217 3420df8cb91b | 2310 | 529 | 12417 | 53302 | 846760 |
| V9 X1 c48f8e40e8c6 | 2892 | 569 | 2368 | 12136 | 192624 |
| Original 251 96f811dc1317 | 1340 | 321 | 1847 | 9749 | 151676 |

Static analysis only. Counts are potential alternative executions, not eliminated instructions, hot-path frequency or runtime admission. Nick skill paint a0 has 9 spans/36 ops, Auto Class_hpa.run only 1 span/4 ops: this engine alone cannot deliver deep render elimination or the CPU goal. No archive is modified or committed.

## Verification

Local GCC and Clang ASan/UBSan test: 20,000 exact stack/local span comparisons including stale reference lanes, integer/long arithmetic, wide iinc, branch/handler entry splitting, fault boundary, truncated switch and JSR refusal. Local OpenJDK -Xint in two independent processes produces PASS 8000 8966399143674533008. CI adds two real independent MiniJVM owners with both previous intrinsic flags off, candidate on only in B, exact Java digest, actual candidate compiles/spans and GC cycles required. CI not yet complete at this checkpoint.

Previous GC callback CI at c491e3e failed for BOTH control and indexed JVMs: finalization completed=64 expected=64, but weak clearing timed out. The initial allocation differential in the same run passed (A 0/16, B 16/16). Do not claim index correctness for weak callbacks. The unchanged strict callback fixture is moved to a separate non-optional CI job (no continue-on-error) so it cannot prevent the new independent compiler and old residual gates from running. No weak semantics change, no waived failure, no default GC activation. A separately logged exception diagnostic leak also remains to investigate.

Reproduce corpus coverage with `python3 tools/ninja_block_ir_audit.py <exact archive paths>` on Linux or macOS with a host C compiler. The script loads the same header through a temporary native library, never writes a game archive and rejects unknown archive hashes.
