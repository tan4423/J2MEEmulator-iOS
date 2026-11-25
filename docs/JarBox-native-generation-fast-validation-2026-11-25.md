# CPU: direct native generation validation (2026-11-25)

Baseline c0cffd8, Codemagic success. Graphics, input and UI native calls repeatedly validate their immutable Java thread generation. Previously they searched all occupied ledger slots by VM pointer and compared the returned generation. The generation already encodes a 1-based slot in its low byte. Use that index to inspect exactly one slot, under the same ledger lock, checking the owner AND complete generation. Never trust the index or VM address alone. Zero, invalid index, foreign owner, stale generation and retired slot all fail closed.

Boot registration and owner-only lookup are unchanged. No change to game timing, GC scheduling, API/boot ABI, heap limits, rendering behavior or network. Reduces scan work, especially for high-index slots and repeated draw calls; not a measured device CPU percentage.

Regression: existing production ledger extraction stress test now exercises direct validation under concurrent accounting, all 64 slots, invalid/foreign keys, retirement and address reuse. Source regression ensures runtime uses the direct lookup and retains locking and owner+generation checks. Device and complete CI validation remain necessary.
