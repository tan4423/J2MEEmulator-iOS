#ifndef JARBOX_SCENE_GPU_GATE_H
#define JARBOX_SCENE_GPU_GATE_H
#include <pthread.h>
#include <stdatomic.h>

// One gate for live 2D Metal and diagnostic replay submissions. Lifecycle
// setters are serialized by UIKit's main thread. A successful begin owns
// the mutex until the submitted command has completed (or is abandoned).
typedef struct {
    pthread_mutex_t lock;
    atomic_int active;
} JarBoxSceneGpuGate;
#define JARBOX_SCENE_GPU_GATE_INITIALIZER { PTHREAD_MUTEX_INITIALIZER, 0 }

static inline int jarbox_scene_gpu_is_active(JarBoxSceneGpuGate *g) {
    return atomic_load_explicit(&g->active, memory_order_acquire) != 0;
}
static inline void jarbox_scene_gpu_set_active(JarBoxSceneGpuGate *g, int active) {
    // Reject new work before draining a previously accepted command.
    if (!active) atomic_store_explicit(&g->active, 0, memory_order_release);
    pthread_mutex_lock(&g->lock);
    if (active) atomic_store_explicit(&g->active, 1, memory_order_release);
    pthread_mutex_unlock(&g->lock);
}
static inline int jarbox_scene_gpu_try_begin(JarBoxSceneGpuGate *g) {
    if (!jarbox_scene_gpu_is_active(g) || pthread_mutex_trylock(&g->lock)) return 0;
    if (!jarbox_scene_gpu_is_active(g)) {
        pthread_mutex_unlock(&g->lock);
        return 0;
    }
    return 1;
}
static inline void jarbox_scene_gpu_end(JarBoxSceneGpuGate *g) {
    pthread_mutex_unlock(&g->lock);
}
#endif
