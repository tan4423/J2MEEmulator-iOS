# Host multi-JVM smoke test

Runs N real MiniJVM instances on N pthreads in one process, headless (no iOS needed).
Render/UI/audio/3D and the sljit JIT are NOT exercised (JIT and TLS are stubbed).

    tools/host_multivm_smoke/run.sh asan 17   # 3 scenarios x 17 = 51 runs, ASan+UBSan
    tools/host_multivm_smoke/run.sh tsan 3    # TSan is ~1 min/run on 1 core
    tools/host_multivm_smoke/run.sh plain 1

Needs gcc and a JDK 21 (`java -m jdk.compiler/...` is used as javac, target 8).
Scenarios: `pair` (A,B concurrent), `stop_a` (stop A mid-run, B must finish), `restart`
(A restarts while B lives). ASan runs disable UBSan `alignment`/`shift-base` because the
interpreter reads unaligned u16 bytecode on purpose.

Recorded (2026-11-22, HEAD b1c6bcc + local fixes): plain 3/3 PASS, ASan+UBSan 51/51 PASS,
TSan: only global-variable races were `jnienv` (fixed with pthread_once) and
`g_native_heap_lock` (own spinlock, non-atomic owner read). Intra-JVM races
(spinlock.h, thread flags) are pre-existing and not Multi-JVM specific.
