# Allocation-free method parameter scan (2026-11-25)

Baseline 74b2c10. The previous parser copies the entire descriptor and repeatedly moves the remaining substring. Both Methodref and InterfaceMethodref also allocate a temporary output string merely to compute slot counts.

For ordinary descriptors, scan the original bytes in linear time, collect at most 255 slot markers on the stack and append only once after validation. Count-only callers skip the output completely. Preserve '4', '8', 'R' markers, wide primitive slots and single-slot arrays/references. Keep original parser as fallback for unsupported input; this is not a malformed-class verification fix. No sharing of JClass, MethodInfo, runtime bytecode or Java state. No JIT or network changes.

Host helper checked with ASan/UBSan against 11,607 unique descriptor-shaped inputs extracted from the five supplied JARs and generated cases; eight rejected fast paths preserve output. Stub UTF8 append only, not full JVM. CI regression compiles the helper extracted from production source. Device startup, RAM and CPU changes have not been measured. Prior miss-cache CI still had no check-run at preparation time.
