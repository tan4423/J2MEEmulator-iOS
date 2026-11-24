#ifndef J2ME_INPUT_H
#define J2ME_INPUT_H

#include "jvm.h"

#ifdef __cplusplus
extern "C" {
#endif

// Input event types
#define J2ME_INPUT_POINTER_PRESSED  0
#define J2ME_INPUT_POINTER_DRAGGED  1
#define J2ME_INPUT_POINTER_RELEASED 2
#define J2ME_INPUT_KEY_PRESSED      3
#define J2ME_INPUT_KEY_RELEASED     4
#define J2ME_INPUT_KEY_REPEATED     5

/// Register a dedicated per-JVM input ring and Display wait context.
/// Returns 1 on success, 0 if no context could be reserved.
int j2me_input_reg_natives(MiniJVM *jvm);

/// Bind physical iOS input focus to this already-registered JVM.
/// Does not create, start or resume any JVM.
int j2me_input_focus_vm(MiniJVM *jvm);
void j2me_input_park_vm(MiniJVM *jvm);

/// Unbind and clear only this JVM's input and wake condition, during
/// its own shutdown. Must never reset another still-running JVM.
void j2me_input_release_vm(MiniJVM *jvm);

/// Post a touch event from iOS (called from main thread).
/// @param type  J2ME_INPUT_POINTER_PRESSED/DRAGGED/RELEASED
/// @param x     Virtual canvas X coordinate
/// @param y     Virtual canvas Y coordinate
void j2me_input_post_touch(int type, int x, int y);

/// Post a key event from iOS (called from main thread).
/// @param type    J2ME_INPUT_KEY_PRESSED/RELEASED/REPEATED
/// @param keyCode J2ME key code
void j2me_input_post_key(int type, int keyCode);

/// Generation-bound key event for sound completion callbacks. Call on the
/// iOS main thread to preserve the input ring's single-producer contract.
uint64_t j2me_input_binding_generation(MiniJVM *vm);
void j2me_input_post_key_to_vm(MiniJVM *vm, uint64_t generation,
                              int type, int keyCode);

/// Set virtual canvas size for coordinate conversion.
void j2me_input_set_canvas_size(int width, int height);

/// Reset input state (clear ring buffer). Call between game sessions.
void j2me_input_reset(void);

// Diagnostic idle Display wait; defaults off and never affects normal mode.
void treo_display_wait_set(int enabled);
/// Park/unpark only the owner with this immutable session token. Returns 0
/// when the token is stale, STOPPING, or not yet bound to a live JVM.
int treo_display_wait_set_for_token(uint64_t token, int enabled);
void j2me_display_wake(void);
void j2me_display_wake_for_vm(MiniJVM *jvm);
uint64_t treo_display_poll_calls(void);
uint64_t treo_display_wait_calls(void);
uint64_t treo_display_gc_safe_wait_calls(void);
uint64_t treo_display_wait_timeouts(void);
uint64_t treo_display_wake_signals(void);

#ifdef __cplusplus
}
#endif

#endif /* J2ME_INPUT_H */
