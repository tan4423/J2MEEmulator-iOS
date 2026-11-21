# Treo bytecode-pattern int-array lookup (experimental, opt-in)

## Evidence from the actual uploaded Ninja JAR (2026-11-21)

Inspected `Nick-B25-Map37-Farm-Clean-CPU.jar` directly (SHA-256 prefix `7e1cff13508f0c43`, 323 .class files). The sampled PaintHot run counted 156357 invocations of `Class_hii.q3(II)I` in 103 sampled paints. It was heavily instrumented (sampled average paint 26.97ms; uninstrumented average paint 8.02ms), so the sampled self CPU cannot predict uninstrumented savings.

`javap -c -v -p Class_hii` confirms:

```
private static int q3(int, int);
0: getstatic x3:[I
3: iload_1
4: getstatic j1:I
7: imul
8: iload_0
9: iadd
10: iaload
11: ireturn
12: astore_2
13: sipush 1000
16: ireturn
Exception table: 0..11 -> 12 java/lang/Exception
```

The method looks up a map cell and returns 1000 for handled failures. `Class_hii.k1` invokes it from tile drawing, **but also writes static fields**, so skipping `k1` or its whole paint branch would not be shown safe.

Also inspected `MicroEmulator.jar.jar` (450 classes; reference Java desktop emulator, not the deployed iOS native runtime) and `Avatar258.jar` (321 classes). These archives are not changed or repackaged.

## Candidate implementation

The experimental native `execute_method_impl` fast path recognizes **exactly** the 17-byte structural pattern above, without checking any game, class, or method name. It is not activated for all short methods. It additionally requires:

- `(II)I` signature, static and nonsynchronized, nonnative method with an initialized class, no debugger/breakpoint/suspension.
- Exact instruction sequence, 17-byte method, and a single exception-handler range from 0 through 11 to handler 12.
- Both referenced static fields already resolved, owned by the method class, nonvolatile and typed `[I` and `I`.
- Referenced object really is an array, and computed Java-style 32-bit wrapping index is in bounds.
- JarBox Treo mode 8 and opt-in build flag.

The method's actual static array and row width are loaded **on every invocation** (not cached). No JAR bytes, graphics calls or game state are changed. If any guard fails, the *original* interpreter executes the method, including its Java exceptions and catch path. The guard itself has overhead; neither CPU benefit nor universal equivalence has been measured on iPhone. This is a narrowly scoped trial, not a general-purpose JIT.

### Independent, matched Codemagic A/B

Branch: `loader-ios-jit-probe`

- **`J2ME Treo Array Lookup ON experimental unsigned`** — `TREO_VM_ARRAY_LOOKUP_EXPERIMENT=1`, PaintHot OFF, Image Cache OFF.
- **`J2ME Treo Array Lookup OFF baseline unsigned`** — same source/configuration, only this single flag OFF.

Default `J2ME Treo JIT probe unsigned` retains feature OFF.

Build script prints `[JarBoxVM][BUILD] array_lookup=on/off`. After leaving Treo, `[JarBoxVM][Treo]` now includes `array_lookup=on/off` and `array_lookup_fast_calls~N` (batched 64). A zero count ON means the matcher failed to activate or the tested scene did not execute a qualifying method; **do not interpret as performance optimization**.

## Validation before promotion

1. Codemagic must actually compile both workflows; static source review alone does not prove iOS build success. Read build errors and fix source on the experiment branch if necessary.
2. Install the OFF baseline IPA, enter the same Ninja JAR scene (game-side sleep/Treo OFF), use JarBox Treo mode 8 for approximately 120–180s, then check game progress/network and correct screen/input/brightness wake. Capture GC, Treo and Canvas logs.
3. Install the ON candidate and repeat the same workload; collect `array_lookup_fast_calls~`, CPU app/paint/GC, heap, paint rate, thermals, skipped/real pixels, and functional behavior. Prefer an A-B-A repetition to expose drifting state and noise.
4. Test off-by-one/bounds edge scenes and normal foreground game; then test Avatar as a cross-JAR regression check. A pattern non-match in Avatar simply falls back to existing behavior.
5. Keep only if measured CPU savings replicate, and never claim watt/energy reduction without power evidence. Restore the OFF default if crash, save corruption, game logic regression, or CPU neutral/worse.

Important: No code in the *game JARs* is changed, and branch `main` remains untouched. No new build or device A/B result is claimed by this document.

## ON build 100.1s, measured 2026-11-21

Correct experimental IPA (`array_lookup=on`, PaintHot disabled) ran 100.1s, `app_CPU=36.1%`, `paint_CPU=205.05ms/s`, `main_CPU=0.1%`, `array_lookup_fast_calls~0` (64-call batching), `paint=25.12/s`, `smart_GC=53`, GC 16.19ms/s, heap 19.7MiB. 2,514 Canvas raster skips, zero fallback, thermal state nominal and GC 500ms restored. This **does not** demonstrate improved performance; a feature compiled ON is not proof it matched and executed. Do not make a candidate-vs-baseline CPU claim yet.

Rechecked the uploaded Ninja JAR with `javap -c -p Class_hii`: `q3(II)I` really has 17 code bytes, `getstatic; iload_1; getstatic; imul; iload_0; iadd; iaload; ireturn; astore_2; sipush 1000; ireturn`, with exception table `0..11 -> 12 java/lang/Exception`. Yet the VM may transform opcodes/exception metadata at runtime, or one of the method/field guards may reject the method. Those are hypotheses, **not** known causes. Do not loosen guards or bypass exceptions blindly.

Added **`J2ME Treo Array Lookup path diagnostic unsigned`**, PaintHot OFF with compile-time experimental stage counters. This workflow reports `[JarBoxVM][ArrayLookupDiag]` on Treo exit: `arity_calls` means any static two-argument/one-slot-return method; `shape_calls` narrows this to 17-byte code, `loose_calls` matches three characteristic instruction positions, `match_calls` meets all bytecode/exception-table guards, `entered_calls` passes thread/debugger guards, `fields_resolved`, `types_ok`, `array_ok`, and `inbounds_fast` isolate remaining guard stages. A one-time sample shows the actual 17-byte candidate's selected opcode positions and handler range; it is **not** a raw JAR modification or hot-loop printf. Counts are batched/64 and cumulative over the process. This diagnostic has observer overhead; do **not** use its app CPU as A/B speed evidence.

**Next device action:** build only the diagnostic workflow on `loader-ios-jit-probe`, run the same Ninja map in JarBox mode 8 ~100–150s, and send `[JarBoxVM][ArrayLookupDiag]`, full `[JarBoxVM][Treo]`, and Canvas/GC summaries. Decide if the matcher is too strict or if the actual game execution differs from the supplied JAR, then fix the specific cause and return to ON/OFF workflows. No need to run OFF again until the candidate proves it executes.
