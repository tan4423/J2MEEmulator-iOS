# Shared immutable JAR entry bytes and API audit

Baseline b307850 passed Codemagic (no new device test). NST reaches login on cebdaa2; real HTTP timeout support remains missing. TrungDucTV intermittent warning remains open. No network or game logic changes in this commit.

Classpath only: the existing four reader slots now retain a bounded immutable copy of successful small decompressed entries (classes or resources). Global payload/header/name budget 6 MiB, maximum 2048 entries, 256 KiB per entry, exact names in per-reader hash buckets. Hits skip ZIP locate/inflate; each VM still receives a private mutable copy. Archive identity check, nonblocking reader-lock fallback, file replacement, reader eviction and existing memory warning trim remain in effect. No Java references, parsed class metadata, mutable resources, RMS, network responses or pixel buffers shared. This may improve repeated starts, not necessarily the first cold start; it adds bounded native cache memory and is not a demonstrated RAM saving.

Regression fixtures cover byte ownership, allocation failure, exact-case collisions, oversized entries, total budget, same-path replacement and trim. The API auditor no longer skips symbolic references owned by game subclasses, checks inherited interface fields and non-inherited constructors, and reports bounded caller provenance. No API stubs, no game JAR modifications. CI and device timings still needed.

Pre-push discipline: check HEAD, review changed call sites and regression fixtures; distinguish host tests from full native/iOS checks. If full CI cannot run locally, state that limitation instead of claiming success.
