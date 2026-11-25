#ifndef JARBOX_CPU_WINDOW_H
#define JARBOX_CPU_WINDOW_H
#include <stdint.h>
// CPU nanoseconds, one core = 100%. Process includes all sessions and UIKit.
enum { JARBOX_CPU_RUNNER=0, JARBOX_CPU_JAVA=1, JARBOX_CPU_GC=2, JARBOX_CPU_KINDS=3 };
typedef struct {
    uint64_t wall_ns, process_ns, runner_ns, java_ns, gc_ns;
    uint64_t gc_cycles, requests, skips, errors;
    int process_ok;
} JarBoxCpuPoint;
typedef struct {
    uint64_t start_ns, end_ns, elapsed_ns, process_ns, runner_ns, java_ns, gc_ns;
    uint64_t gc_cycles, requests, skips, sample_errors;
    int mode, valid, process_ok, threads_ok;
} JarBoxCpuWindow;
typedef struct {
    JarBoxCpuPoint start;
    JarBoxCpuWindow last_visible, last_treo;
    int initialized, mode;
} JarBoxCpuHistory;
typedef struct { JarBoxCpuWindow current, last_visible, last_treo; } JarBoxCpuSnapshot;
static inline JarBoxCpuWindow jarbox_cpu_window(JarBoxCpuPoint a, JarBoxCpuPoint b, int mode) {
    JarBoxCpuWindow w={0};
    w.mode=mode; w.start_ns=a.wall_ns; w.end_ns=b.wall_ns;
    if (!a.wall_ns || b.wall_ns<=a.wall_ns) return w;
    w.valid=1; w.elapsed_ns=b.wall_ns-a.wall_ns;
    w.process_ok=a.process_ok && b.process_ok && b.process_ns>=a.process_ns;
    if (w.process_ok) w.process_ns=b.process_ns-a.process_ns;
    // Fail closed after any failed thread sample in this session.
    w.sample_errors=b.errors;
    w.threads_ok=!a.errors && !b.errors && b.runner_ns>=a.runner_ns &&
        b.java_ns>=a.java_ns && b.gc_ns>=a.gc_ns;
    if (w.threads_ok) {
        w.runner_ns=b.runner_ns-a.runner_ns;
        w.java_ns=b.java_ns-a.java_ns;
        w.gc_ns=b.gc_ns-a.gc_ns;
    }
    if (b.gc_cycles>=a.gc_cycles) w.gc_cycles=b.gc_cycles-a.gc_cycles;
    if (b.requests>=a.requests) w.requests=b.requests-a.requests;
    if (b.skips>=a.skips) w.skips=b.skips-a.skips;
    return w;
}
static inline void jarbox_cpu_history_transition(JarBoxCpuHistory *h,int mode,JarBoxCpuPoint p) {
    if (!p.wall_ns || (h->initialized && h->mode==mode)) return;
    if (h->initialized) {
        JarBoxCpuWindow w=jarbox_cpu_window(h->start,p,h->mode);
        if (h->mode) h->last_treo=w;
        else h->last_visible=w;
    }
    h->start=p; h->mode=mode; h->initialized=1;
}
static inline JarBoxCpuSnapshot jarbox_cpu_history_snapshot(const JarBoxCpuHistory *h,JarBoxCpuPoint p) {
    JarBoxCpuSnapshot out={0};
    out.last_visible=h->last_visible; out.last_treo=h->last_treo;
    if (h->initialized) out.current=jarbox_cpu_window(h->start,p,h->mode);
    return out;
}
#endif
