# Experimental constant handler chaining

CI at a8d0810 is queued, not green. Do not enable by default. This checkpoint adds two independent, compile-time opt-in interpreter experiments; no default runtime behavior change. The original handlers execute both operations; only the dispatch loop between them can be avoided. No JIT, bytecode rewrite, changed Java stack layout, shared mutable state, or changed timing policy.

- Arithmetic: iconst_m1..5, bipush, sipush followed by iadd/isub/imul/ishl/ishr/iushr/iand/ior/ixor. No division, remainder, allocation, calls or exceptions added.
- Branch: those constants followed by if_icmpeq..if_icmple, only if three bytes remain. The existing branch handler retains PC-relative offsets and check_gc_pause on taken branches. Exactly one additional handler is entered; it cannot chain again.
- Switch, JDWP, profile and debug paths remain unfused. The code-end guard is shared with the existing aload-field fusion. The two Codemagic flags JARBOX_VM_CONST_ARITH_FUSION_EXPERIMENT and JARBOX_VM_CONST_BRANCH_FUSION_EXPERIMENT default to 0; use independent matched A/B builds after CI recovery. No logging or counter per opcode.

Static candidate scan with javap -c -p on the supplied original and five mods (instruction adjacency, not measured execution frequency, not proof of benefit):

| JAR | constant + arithmetic | constant + if_icmp |
|---|---:|---:|
| NinjaSchool_251 | 4848 | 4844 |
| Nicknsonet_t5 | 5502 | 6688 |
| 217_TrungDucTV_51026 | 17840 | 0 |
| NST_X1 | 4067 | 0 |
| V9_X1 | 5367 | 6151 |
| V9_X1_NOKEY | 5365 | 6151 |

Host test: production macro and selection gate, independent arithmetic/branch model, 131072 cases per configuration; eight configurations (off, arithmetic, branch, both, switch, profile, debug log, debug macro). GCC and Clang strict warnings, Clang ASan/UBSan. Source assertions check actual integration, unchanged opcode numbering and safepoint calls. No full iOS build or actual game execution. Measure total CPU and startup before any default enable: check cost on nonmatching constant instructions, code size and runtime compatibility. Not a decoded interpreter or compact stack implementation.
