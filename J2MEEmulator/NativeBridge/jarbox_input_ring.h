#ifndef JARBOX_INPUT_RING_H
#define JARBOX_INPUT_RING_H

// A JVM owns exactly one ring. This portable SPSC implementation is used
// by the real iOS input bridge and is tested independently of UIKit.
// A ring is never shared between two independent Java heaps.
// One physical input producer and one Java polling consumer per ring.
#include <stdatomic.h>
#include <stdint.h>

#define JARBOX_INPUT_RING_CAPACITY 256U
#define JARBOX_INPUT_RING_MASK (JARBOX_INPUT_RING_CAPACITY - 1U)

typedef struct {
    int type;
    int x;
    int y;
    int keyCode;
} JarBoxInputEvent;

typedef struct {
    JarBoxInputEvent events[JARBOX_INPUT_RING_CAPACITY];
    atomic_uint write_pos;
    atomic_uint read_pos;
} JarBoxInputRing;

// Reset is legal only when the owning Java consumer has been detached
// and no other thread may enqueue into this ring.
static inline void jarbox_input_ring_reset(JarBoxInputRing *ring) {
    atomic_store_explicit(&ring->write_pos, 0U, memory_order_relaxed);
    atomic_store_explicit(&ring->read_pos, 0U, memory_order_relaxed);
}

static inline int jarbox_input_ring_push(JarBoxInputRing *ring,
                                         const JarBoxInputEvent *event) {
    const unsigned wp = atomic_load_explicit(&ring->write_pos,
                                              memory_order_relaxed);
    const unsigned next = (wp + 1U) & JARBOX_INPUT_RING_MASK;
    if (next == atomic_load_explicit(&ring->read_pos, memory_order_acquire))
        return 0; // Full; do not overwrite an unread game event.
    ring->events[wp] = *event;
    atomic_store_explicit(&ring->write_pos, next, memory_order_release);
    return 1;
}

static inline int jarbox_input_ring_pop(JarBoxInputRing *ring,
                                        JarBoxInputEvent *event) {
    const unsigned rp = atomic_load_explicit(&ring->read_pos,
                                              memory_order_relaxed);
    if (rp == atomic_load_explicit(&ring->write_pos, memory_order_acquire))
        return 0;
    *event = ring->events[rp];
    atomic_store_explicit(&ring->read_pos,
                          (rp + 1U) & JARBOX_INPUT_RING_MASK,
                          memory_order_release);
    return 1;
}

#endif // JARBOX_INPUT_RING_H
