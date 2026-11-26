# Ninja effect-preserving paint slicing — M0/M1 baseline (2026-11-26)

User direction: preserve every observable paint effect; remove only work proven to feed display-only sinks. No VM change yet. Do NOT reactivate automatic mode 8. Existing mode 1 and pending QoS candidate stay unchanged. No JAR committed or rewritten.

## Actual static evidence

Ran javap -p -s -c on every class in the three locally supplied JARs with tools/ninja_paint_slice.py. Output is SHA-256 keyed; count distinct symbolic field references and instruction sites, not runtime effects, code bytes, CPU weights, or a complete verified call graph. The hierarchy approximation may overreach or miss inherited implementations/library callbacks. Implicit class initialization, reflection, aliasing and exceptional control-flow are not solved. Do not authorize elision from this report.

| Archive (SHA-256) | Classes | Paint root | Potential methods | Instructions | Direct possible sinks | Query refs | Wrapper candidates/calls | Local args direct/wrapper | Combined conditional instruction share |
|---|---:|---|---:|---:|---:|---:|---|---|---:|
| NinjaSchool_251 (96f811dc1317ec41ba01953350436dc8f850090c3018a26b4ae35f3124c2e95d) | 130 | main/b.paint | 387 | 86416 | 7 | 74 | 7 / 531 | 37 / 242 | 817 / 86416 = 0.945% |
| Nicknsonet_t5 (11b1d4c11f9082b9d07bc7bd92a9ad3abad40764853e23686cc86686869c966c) | 296 | Class_hef.paint | 622 | 96266 | 8 | 131 | 8 / 561 | 43 / 300 | 912 / 96266 = 0.947% |
| TrungDucTV (3420df8cb91bcc33852230d1c6f9166a99d6ce3f2c4a332cf1bad851c3f7b276) | 184 | Class_ek.paint | 410 | 132767 | 8 | 75 | 7 / 538 | 37 / 12 | 595 / 132767 = 0.448% |

Original wrappers are t, Nick Class_hvi, TrungDucTV Class_gp. Similar structure, not proof of identical behavior. Conditional counts sum direct draw sites, wrapper call sites and contiguous argument expression instructions; no receiver provenance or actual rewriting; zero proven removable instructions at this stage. Conditional wrapper call elimination would require keeping null checks, field reads/class initialization and all other relevant effects. This modest static fraction says nothing about dynamic cost inside loops. No 18–22 percentage-point Java-side CPU attribution established by latest paint-only counters.

Original root main/b.paint -> main/c.a(Graphics), potential implementation main/a.a(Graphics). Actual offsets:
- main/a.a(Graphics) pc5 putfield t.a:Graphics, another writer t.<init>(Graphics) pc6; twelve symbolic read sites in t wrappers (includes t.a()I and t.b()I queries).
- main/a.aM:I putstatic pc156, no direct symbolic read found in complete JAR. The width result is duplicated at pc155 and used by subsequent condition; keep unless independently proven dead.
- main/a.aK:I putstatic pc171,183; initial write main/a.<clinit> pc104, reads main/a.a(Graphics) pc165 and 209. This looks like scrolling text position (subtract one, reset at -440, draw at aK+20); private static fields, not evidence of auto stall. Keep initially.
- Other fields with the same short name, such as df.aK:String and df.aM:String, are separate and have outside-graph readers. Never identify effects by short name alone.
- The original method has an exception handler for pc8..230; retain exception behavior. The graph includes 993 symbolic fields with potential writes, 1415 array store sites, 5 synchronized methods, 60 methods with exception tables. This is static inventory, not observed writes in each frame.

## Required milestones before authorization

M0 dynamic trace still incomplete. Sample bounded per-owner traces of stores (field/static/array), monitor/sync, I/O, time/random, exception/return, graphics state and target identity, query results, object allocation/escape and unresolved calls. Keep sequence and site IDs, normalize object identities, record overflow and fail closed. Record real progress separately from repaint heartbeat. Only trace under an explicit diagnostic configuration after agreement to change VM.

M1 next: binary classfile CFG with exceptional successors, stack/local def-use SSA, receiver points-to and Canvas vs Image provenance, call summaries, implicit initialization, memory/alias and control dependencies. Preserve all unknowns and exceptions; calculate both static and dynamic weighted removable work. Begin with seven straight-line wrapper shapes then reach their caller operand dependencies. Keep setters and queries until proven irrelevant. Cache analysis by archive SHA + boot API/VM ABI/analyzer version, with bounded work. Structural recognition is a discovery aid only; no new runtime allowlist yet.

M2 (future, not implemented): per-VM immutable specialized code overlay, select only at a verified safe method entry/transition; pin code for active frames, don't swap shared prepared-code pointers or mutate another JVM. Preserve GC maps, stack verification, exception table, class-init checks, synchronization, bytecode indices and debugger semantics. Wake must restore original code and full redraw before publishing any stale pixels. No JIT and no tick changes.

M3: compare original and candidate from equivalent isolated state, same nondeterministic inputs (clock/random/network). Never run a second live paint on the same mutable game just to compare, as that doubles writes, I/O or sync effects. A periodic original frame on live game can be an observation/probe, not a differential oracle without an equivalent snapshot/replay. Sticky per-owner fallback and reject profile on mismatch; canary cannot make unproven irreversible effects safe. M4 only after proof of render-only field alias/liveness across whole program, including wake reconstruction.

## Validation actually performed

All three actual JARs successfully disassembled and analyzed. Four Python unit tests for parser/field identity/category and conservative local suffix logic passed locally. These are synthetic static analyzer fixtures, not real MiniJVM runs. GitHub clone failed locally (DNS), no full source checkout; existing tools/host_multivm_smoke runs a real MiniJVM when built but explicitly excludes LCDUI and uses native stubs. It does not currently run a Ninja MIDlet or compare paint. Adapt that harness to real MiniJVM plus deterministic LCDUI/native effect journal, with two equivalent isolated runs and local JARs; do not claim a real dynamic test until actually executed. No iOS test or CPU benefit claimed.

Run:
  python tools/ninja_paint_slice.py /path/to/NinjaSchool_251.jar --output /tmp/ninja-paint.json
  cd tools && python -m unittest test_ninja_paint_slice

No runtime, build flag, workflow or game code changes in this research milestone.
