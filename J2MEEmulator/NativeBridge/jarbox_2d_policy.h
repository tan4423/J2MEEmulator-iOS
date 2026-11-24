#ifndef JARBOX_2D_POLICY_H
#define JARBOX_2D_POLICY_H

// Default releases retain legacy 3D support with one active JVM.
// An opt-in 2D-only build can exercise exclusion without raising the cap.
#ifndef JARBOX_2D_ONLY_RUNTIME
#define JARBOX_2D_ONLY_RUNTIME 0
#endif

// Never register a process-global 3D backend in a multi-VM build,
// even when only the first of its slots is currently occupied.
static inline int jarbox_legacy_3d_allowed(unsigned session_cap) {
    return session_cap == 1 && !JARBOX_2D_ONLY_RUNTIME;
}
#endif
