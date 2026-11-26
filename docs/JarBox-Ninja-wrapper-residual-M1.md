# Ninja wrapper residual plans — M1 local def-use extension

Read-only continuation of c810948. No runtime or build configuration changes. The supplied V9_X1_NOKEY.jar was inspected directly: SHA-256 c48f8e40e8c619a8503626b14940693d3fd37f1ecbba1c1342f53957d42f0080, 291 classes, root cu.paint(Graphics), 464 potential paint methods, 90162 instructions in the approximate graph, 8 wrapper shapes in eg, 549 potential wrapper callsites, 81 query sites, 987 symbolic fields written from the graph, 1363 array-store sites and 65 methods with exception tables. These are static inventories, not observations of live effects or proof of pixel independence. No V9 runtime authorization.

The new offline analyzer tracks operand stack and local definitions for straight-line single-draw wrappers. Field reads remain ordered mandatory nodes (including class initialization, resolution, null and possible volatile effects). Backward dependencies preserve the exact receiver and all mandatory reads. Nonthrowing integer arithmetic/local stores only feeding the draw arguments are conditional dead nodes. A future guarded residual IR must retain original input values and ordered field read results, materialize original arguments on guard miss, and perform exact receiver/target/owner/headless checks at the original call, including required exceptions and resolution. Do not reread fields for fallback or treat this plan as legal JVM stack bytecode. No type verifier, full CFG, full points-to analysis, exception proof or executable residual exists. Reject branches, handlers, synchronization, unknown calls, writes, allocation and division. JAR SHA and class SHA are recorded; actual runtime needs verified class/method identity, API and VM ABI, verified bytecode and debugger/GC/stop gates. No use of this JSON as an allowlist.

Actual local runs:
| JAR | Plans | Conditional dead nodes | Original instruction nodes | Mandatory field reads |
|---|---:|---:|---:|---:|
| NinjaSchool_251 | 7 | 133 | 193 | 39 |
| Nick t5 | 8 | 151 | 219 | 44 |
| TrungDucTV | 7 | 133 | 193 | 39 |
| V9 NOKEY | 8 | 151 | 219 | 44 |

30 plans, 568/824 conditional dead nodes (~69% in selected wrapper bodies only), 166 mandatory field reads. No claim of CPU savings or proven removable runtime instructions. For example t.a(IIII)V has 24 instructions, 16 conditional dead nodes and eight retained nodes including four scale reads, receiver load/read, guarded call and return. The retained sequence is not executable bytecode. The four older census tests plus four new unit tests passed locally; actual JAR analysis completed. The local git ls-remote attempt still failed with GitHub DNS resolution. Real miniJVM effect trace and differential execution not performed; existing smoke harness excludes LCDUI. Next step is a typed verified residual executor / differential harness with ordered effects, first off-device; no automatic deep mode until validated.

Run from checkout:
    python tools/ninja_paint_slice.py /path/to/game.jar --output /tmp/inventory.json
    python tools/ninja_wrapper_residual.py /path/to/game.jar --inventory /tmp/inventory.json --output /tmp/residual.json
    cd tools && python -m unittest test_ninja_paint_slice test_ninja_wrapper_residual
