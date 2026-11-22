#ifndef JARBOX_RUNTIME_GENERATION_H
#define JARBOX_RUNTIME_GENERATION_H
#include <stdint.h>
// A recycled MiniJVM address must never authorize a previous Java thread.
static inline uint64_t jarbox_runtime_generation_if_current(
        uint64_t captured_generation, uint64_t live_generation) {
    return captured_generation && captured_generation == live_generation
        ? captured_generation : 0;
}
#endif
