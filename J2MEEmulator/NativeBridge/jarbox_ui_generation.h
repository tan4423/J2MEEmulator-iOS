#ifndef JARBOX_UI_GENERATION_H
#define JARBOX_UI_GENERATION_H

#include <stdint.h>

// A reused numeric slot does not confer ownership. Native heap generation
// tokens are never reused, even when a MiniJVM pointer address is recycled.
static inline int jarbox_ui_generation_matches(uint64_t bound_key,
                                                uint64_t current_key) {
    return bound_key != 0 && bound_key == current_key;
}

// An asynchronous UIKit action is allowed only while its creating JVM still
// owns BOTH the focused MIDP UI and visible rendering destination.
// Parked sessions have no visible render key and cannot present UIKit.
static inline int jarbox_ui_may_present(uint64_t origin_key,
                                        uint64_t focused_key,
                                        uint64_t visible_render_key) {
    return jarbox_ui_generation_matches(origin_key, focused_key) &&
           jarbox_ui_generation_matches(origin_key, visible_render_key);
}

// A focus replay may only use an action that was published for the exact
// completed screen revision, never combine an old action with a new build.
static inline uint64_t jarbox_ui_notice_pack(int action, int revision) {
    return ((uint64_t)(uint32_t)revision << 32) | (uint32_t)action;
}
static inline int jarbox_ui_notice_action(uint64_t notice, int revision) {
    if ((uint32_t)(notice >> 32) != (uint32_t)revision) return 0;
    return (int)(uint32_t)notice;
}

#endif // JARBOX_UI_GENERATION_H
