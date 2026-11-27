# Java integer semantics prerequisite for residual execution

Host CI on 0db7f5d failed at interpreter.c:3467, signed overflow 2145572725 + 1013904223, while executing the actual two-MiniJVM residual fixture under UBSan. Previous gates including actual intrinsic differential passed. The new gate deliberately exercises Java overflow. Do not suppress the sanitizer or constrain the workload to hide it.

Make ordinary int/long add/subtract/multiply/negation and narrow/wide iinc use unsigned modulo arithmetic with bit-preserving conversion. Handle MIN/-1 division and remainder (zero still follows existing exception path). Mask shift counts as Java requires; arithmetic right shifts use explicit sign fill. Existing stack layout, PC advancement, exception dispatch and scheduling remain unchanged. JIT and unrelated floating-point paths are not modified. The same interpreter is the reference for future residuals. Add explicit variable-operand Java assertions to both original/residual fixture workloads, including negative and oversized shift counts, zero-divisor exception, MIN/-1 and increment overflow. No default optimization or live paint changes. This is a correctness prerequisite, not evidence of CPU savings or cause of historical stall.

Original failing job: https://github.com/tan4423/J2MEEmulator-iOS/actions/runs/45941247574/job/140315828417
