# Startup classpath optimization and NST diagnostics

Device baseline (294cdce): first_surface=canvas 1065.8, 1066.0, 1091.1ms (not full tap-to-interactive). Removing the placeholder did not remove startup work.

- Every classpath lookup previously opened and parsed a ZIP central directory, including misses. Reuse up to four read-only archive readers, only on load_file_from_classpath. Exact case, bounds, extraction by index, path identity validation, nonblocking contention fallback and cache-only memory trim. No Java objects or RMS are shared. No change to the normal ZIP writer/read APIs or 3D admission.
- Separate launch request-to-surface, native admission, save-root and VM-init timings. These are phase measurements, not an interactive-ready guarantee.
- NST_X1 (193 classes): a.run catches Exception over PC37..554 and sleeps/retries; ci.paint delegates to bX. Add budgeted exception-only trace to locate failures even if the game catches them. This is a diagnostic, not a verified fix.
- TrungDucTV: 2/3/1 recorded TCP connection cycles in the three snapshots; no reported transport errors, unknown server response semantics and capture windows. Do not suppress alerts or alter version/protocol.
- Regression: extend production ZIP-wrapper host test with repeated case-sensitive reads, misses, cache contention fallback, same-path atomic replacement and trim. Full CI and real iPhone timings still required.
