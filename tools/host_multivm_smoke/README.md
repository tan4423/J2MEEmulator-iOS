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

## Current acceptance criteria (2D-first)

The controlling pthread only requests stop while holding the job's
publication lock. The worker returns from call_main, revokes that
publication and destroys its own VM, then retires its native generation.
The long-running test fixture writes a heartbeat every 50 ms; the
controller requires a complete, increasing heartbeat from B after
A's destruction/restart. The short workloads must match the exact
checksum 198715 and the expected private save tag. Startup errors,
missing heartbeats, timeouts and Java compilation errors fail the test.
Each run uses a fresh build directory and fresh save roots.

Run on Linux with the complete checkout:
    tools/host_multivm_smoke/run.sh plain 1
    tools/host_multivm_smoke/run.sh asan 10
    tools/host_multivm_smoke/run.sh tsan 3

The harness deliberately excludes iOS renderer, audio, LCDUI, 3D,
JIT and TLS. A host pass does not establish iPhone concurrency or
authorize raising the application's default cap. Existing historical
results above predate these strengthened assertions.

Current change validation: native orchestration compiled and executed
against mock VM APIs, 60/60 scenarios under ASan+UBSan after fixing
a partial-heartbeat read discovered during the initial run. Java
fixture compiled with OpenJDK 21 targeting Java 8 and ran in two
separate standard JVM processes; verified checksums, loopback socket
exchange and surviving heartbeat after stopping A. Neither is a new
real MiniJVM smoke-test result. Full checkout unavailable in local
environment (GitHub DNS failure), so real MiniJVM and iOS builds not run.
