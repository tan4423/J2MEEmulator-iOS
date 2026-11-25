# Classpath reader LRU (2026-11-25)

Four shared reader slots previously evicted in round-robin order. A recently used boot/API JAR could be discarded when a different game was admitted. Track reader recency under the existing lock, select an empty slot first or the least recently used reader. Update recency only after the archive identity is checked. Trim clears the counter; wrap changes eviction preference only. Positive/negative cache budgets, exact-case lookup, private returned buffers and contention fallback are unchanged.

Host C selection helper passed empty-slot, retouch, eviction and wrap checks with ASan/UBSan using a minimal reader struct. CI regression adds actual ZIP archive admission and retouch to the bundled-miniz test. No iPhone CPU/RAM/startup delta measured; this preserves hot cache entries, not a claimed benchmark.
