#ifndef J2ME_UI_H
#define J2ME_UI_H

#include "jvm.h"
#include <stdint.h>
#include <CoreGraphics/CoreGraphics.h>

#ifdef __cplusplus
extern "C" {
#endif

// UI event types (added to input queue alongside touch/key events)
#define J2ME_UI_COMMAND_ACTION   10
#define J2ME_UI_LIST_SELECT      11
#define J2ME_UI_ALERT_DISMISSED  12

CGImageRef _Nullable j2me_ui_copy_list_icon(int index) CF_RETURNS_RETAINED;
int j2me_ui_get_choice_count(int index);
const char *j2me_ui_get_choice_option(int index, int option);
int j2me_ui_get_form_item_param2(int index);
int j2me_ui_revision(void);
void j2me_ui_lock_screen(void);
void j2me_ui_unlock_screen(void);
void j2me_ui_stage_text(int revision, int index, const uint16_t *units, int count);
void j2me_ui_stage_text_for_owner(uint64_t owner_key, int revision, int index,
                                 const uint16_t *units, int count);

/// Reserve a separate Form/List/Alert screen context for a JVM.
/// Returns 0 if every context is occupied; never shares another VM's state.
int j2me_ui_reg_natives(MiniJVM *jvm);

/// Select the context visible to UIKit. This does not start another JVM
/// or grant safe concurrent execution while renderer/GC remain global.
int j2me_ui_focus_vm(MiniJVM *jvm);
void j2me_ui_park_vm(MiniJVM *jvm);

/// Native generation of the currently focused MIDP screen; zero if parked
/// or released. UIKit must compare this with the frame owner before showing.
uint64_t j2me_ui_focused_owner_key(void);

/// Release only the ending JVM's MIDP UI state after Java threads stop.
void j2me_ui_release_vm(MiniJVM *jvm);
/// Retire a drained screen by immutable native generation.
void j2me_ui_release_for_owner(uint64_t owner_key);

/// Callback for creating/showing native iOS views.
/// Called from JVM thread — implementations must dispatch to main thread.
typedef void (*j2me_ui_callback)(int action, int revision);

/// Set the UI callback.
void j2me_ui_set_callback(j2me_ui_callback callback);

// Every native MIDP UI event carries the creating JVM generation to its
// eventual UIKit dispatch. Prevents queued Form/Alert from a previous tab
// appearing after focus has moved to a different JVM with the same JAR.
typedef void (*j2me_ui_callback_owned)(int action, int revision, uint64_t owner_key);
void j2me_ui_set_owned_callback(j2me_ui_callback_owned callback);

// UI actions for the callback
#define J2ME_UI_ACTION_SHOW_CANVAS    1
#define J2ME_UI_ACTION_SHOW_FORM      2
#define J2ME_UI_ACTION_SHOW_LIST      3
#define J2ME_UI_ACTION_SHOW_ALERT     4
#define J2ME_UI_ACTION_SHOW_TEXTBOX   5

#ifdef __cplusplus
}
#endif

#endif /* J2ME_UI_H */
