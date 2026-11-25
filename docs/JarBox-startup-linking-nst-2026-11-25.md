# Startup linking and NST login

Device on 27522a4: NST request_to_surface=996.2ms, admission=38.4ms, storage=1.9ms, vm_init=46.6ms; TrungDucTV 1141.6ms, admission=46.4ms, storage=1.6ms, vm_init=48.0ms. Most elapsed time remains after native VM initialization. The earlier ZIP-reader cache did not demonstrate a clear first-surface speedup on TrungDucTV.

NST_X1.jar javap: a.run PC409 invokes cp.dG()V; the actual thrown NPE may be in a callee. bW.dG waits for the game's 2-second splash then calls a.b(), bS.a(), bS.bM(). bS reads /x1/tt.png via nso.GameMidlet.a(String), which calls String.class.getResourceAsStream; ZIP contains the exact 94471-byte textual image resource. Add VM-local caller loader fallback on a bootstrap resource miss and bounded nested exception frame trace. No game JAR modification. This is not yet proof that NST login is fixed.

Runtime audit: class_clinit eagerly resolves every external method and field, causing classpath loads even for unused code. On normal iOS interpreter execution, defer external references; preserve pairlists, local prelinks, original JIT-on behavior, checked field first use, and resolve direct invocation before rewriting fast opcode. Wait for CLINITED through the existing recursive VM lock; do not optimize empty calls that could trigger initialization or acquire a monitor. Add manifest/class/constructor/startApp phase timings. No time or GC suppression, no prestarted hidden JVMs, no change to RMS/slot limits.

TrungDucTV javap: acceptance branches GameMidlet.c PC588, Class_cu.q PC153, Class_gv.g PC153. Extend the existing boolean-only diagnostic to these branches; retain old probe. Do not fake a response or hide a warning.

Regression contracts added; full CI and on-device test remain necessary.
