# Ninja Headless — corpus and development contract

## Stable checkpoint

0a65578559833fdf6c17d20c282d01f0853fccdf: host-intrinsics and isolated iOS candidate CI both SUCCESS (runs 45949817178 and 45949817235). The background differential recorded B=1929 admissions, 15090 guarded draw regions, 1551 original-PC continuations and exact output equality. The older closed-draw fixture recorded B=1928 admissions plus one explicitly counted suspend refusal; the eligible total is 1929. This supports the refusal accounting, not a retrospective proof of the earlier missing invocation. Four Nick methods k1/i3/r2/j1 are wired into the isolated iOS candidate. Actual game admission, CPU and long-run gameplay are still unverified. Preserve this checkpoint while developing the broader engine. No repeated scoped-sink-only trial, no default activation.

## Product scope

One Headless/Treo mode, Nick t5 primary, TrungDucTV 217 and V9 X1 mod targets, original NinjaSchool 251 reference. Five exact archives, four code families. Unknown archives use the compatible runtime; analysis identity is not runtime authorization. No game code distributed or rewritten, no JIT or reconstructed independent client, no live server interaction in host tests. Each VM owns heap, static fields, network, RMS, account and scheduler state. Share only proven immutable data.

## Direct corpus evidence

The read-only tool tools/ninja_headless_corpus.py accepts the supplied original archives, verifies full archive SHA256, inventories class hashes, disassembles with javap and checks exact method/PC/opcode/symbol witnesses. Run it locally with the five game archive paths. All five passed locally. Two Nick archives have identical class-set digest. The archive and class-set identity table:
- Nick t5: 296 classes, 3444 declared method records, class set fbb64008d55ade4e99cbe69c84941a938b4b1bbe173628e81f1a0aee6eaf223d.
- Original 251: 130 classes, 1349 records, class set 99cdc4427e5989b2102b375f9d6fd93064818abc1faf63bf159b332bb53fd365.
- Trung 217: 184 classes, 2321 records, class set fc467c0edcceb16aef006b6b14452339f40b42d2d9dccc17ae5c3b441d8de7bb.
- V9 X1: 291 classes, 2904 records, class set 1ea207bc4adaa0c4d30e4c92ac24960180126fa1cb6a495ed4b29262918cd47d.

Paint-to-skill dependency (original PCs):
- Nick Class_hda.a0(Class_hvi): putfield s6 PC1424 after iadd; n1 read PC272, compare at 282, Class_hgh.r PC288, Class_hhh.a(Class_bk) PC30 in service method.
- Original bp.a(t): cV PC1440; J read PC273, compare PC283, dq.r PC289, dh.a(ce) PC30.
- Trung Class_bb.a(Class_gp): ii PC1631; increment operand comes from obfuscated int array (not assumed constant by the tool). al read PC330, compare PC344, Class_fp.r PC350, Class_fq.a(Class_bo) PC34. Completion check ii PC179.
- V9 Q.a(eg): cQ PC1482 (another increment PC147); aZ read PC289, compare PC299, du.iC PC322, dv.X(cj) PC30. Completion check cQ PC148.

The four concrete service methods serialize data before the identified transport-layer call. These are static dependencies, not a claim that every branch fires or every packet reaches a server. The tool records direct named writes (5/5/5/6 sites respectively) and local effect inventory; inherited aliases, reflection, synchronization flags, full CFG, dynamic targets, class init, exception tables and concurrency need additional proof. It never returns runtime_authorized=true. Do not infer a method is pure from these counts. No corpus archives in CI or committed artifacts.

## Two coordinated workstreams

R (residual): preserve the validated Nick candidate and extend whole-program effect-preserving slicing, particularly skill logic, text/allocation and whole loops. Retain raster/ordinary interpreter fallback at correct original PC. Finish each new method with a real two-VM differential and iOS build before live admission.

H (Headless): build a common semantic IR and corpus-specific certificates from actual classfiles. First mandatory roots: paint-driven skill progression, all observable state writes, packet and RMS order, input/timer/RNG, class initialization, exceptions, synchronization, offscreen/pixel reads. Then prove removable regions including text construction, glyph walks, sprite transforms and hidden UI. Keep unknown effects. Optimize remaining gameplay through precompiled C VM operations, not reimplementing Auto. Separately remove measured native idle/polling overhead and unnecessary allocation/GC work; share immutable plans only. No altered game ticks, no fabricated skill/packet progress, no global mutable game state.

Acceptance is by observable gameplay equivalence, not number of removed bytecodes. Test same archive/scene and independent VMs, compare state/effect order/faults and visible wake output; exercise skill/target transitions, map/zone, death/revival, reconnect, RMS, GC/suspend/STOP, foreground/park/wake, two and multiple owners. Device gates: actual plan admission, matched total process CPU (100%=one core), real combat/loot/XP progress and long multi-tab stability. Target <10% on one XS Max remains unverified. Native/iOS fixture builds do not prove actual gameplay.

This commit begins cross-corpus tooling and the broader design; it does not authorize any new runtime elision or claim the Headless engine is finished.
