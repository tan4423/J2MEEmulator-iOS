# Bounded exact-case classpath miss cache

Baseline 38868ab (Codemagic success). The bundled miniz's case-sensitive lookup scans the central directory. Repeated missing class/resource requests from independent JVMs were not cached, although successful small entries were.

Cache only MZ_ZIP_FILE_NOT_FOUND, never failed extraction, allocation or invalid parameters. Share exact entry names only under the existing reader identity and mutex; retain the identity recheck before publishing or returning. Independent process-wide 128 KiB dynamic miss budget and 2048 entry cap; per-reader 256 bucket pointers add about 8 KiB total on 64-bit. No changes to positive cache limits, fallback under contention, Java objects, class resolution order, RMS, JIT, network or GC. Reader eviction, replacement and memory warning trim both maps. A full miss cache falls back to ordinary scans.

Regression extends the existing bundled-miniz C harness: case collision, slash normalization, allocation failure, bounded unique misses, same-path replacement where a missing entry becomes present, and trim. Expected benefit is fewer repeated central-directory scans; device CPU/RAM/startup delta has not been measured. Do not infer a speedup from the cache alone.
