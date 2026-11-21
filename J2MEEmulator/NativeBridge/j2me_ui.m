//
// j2me_ui.m — Native UI bridge for J2ME LCDUI Forms/Lists/Alerts
//
// Java classes serialize their state via sequential native calls.
// Native side accumulates data and creates UIKit views on main thread.
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#include "j2me_ui.h"
#include "j2me_render.h"
#include "j2me_input.h"
#include "jvm.h"
#include "jvm_util.h"

extern void jvm_bridge_note_net_trace(const char *detail);
#include <stdio.h>
#include <pthread.h>
#include <stdatomic.h>

// ============================================================
// Form builder state — accumulated by Java calls, flushed on show
// ============================================================

#define MAX_FORM_ITEMS 64
#define MAX_COMMANDS 8

typedef struct {
    int type;           // 0=string, 1=textfield, 2=choice, 3=image, 4=spacer, 5=gauge
    char label[256];
    char text[1024];
    int intParam1;      // appearance/maxSize/choiceType
    int intParam2;      // constraints
} FormItem;

typedef struct {
    char label[128];
    int type;           // Command.SCREEN, BACK, OK, EXIT, etc.
    int priority;
    int id;             // sequential ID for event matching
} FormCommand;

static char g_form_title[256] = "";
static FormItem g_form_items[MAX_FORM_ITEMS];
static int g_form_item_count = 0;
static int g_choice_item = -1;
static NSMutableDictionary<NSNumber *, NSMutableArray<NSData *> *> *g_form_choices;

int j2me_ui_get_choice_count(int index) {
    return (int)g_form_choices[@(index)].count;
}

const char *j2me_ui_get_choice_option(int index, int option) {
    NSArray<NSData *> *items = g_form_choices[@(index)];
    return option >= 0 && (NSUInteger)option < items.count ? items[(NSUInteger)option].bytes : "";
}
static FormCommand g_form_commands[MAX_COMMANDS];
static int g_form_command_count = 0;
static int g_form_type = 0; // 0=form, 1=list, 2=alert, 3=textbox

// List items
static char g_list_items[MAX_FORM_ITEMS][256];
static int g_list_item_count = 0;
static NSMutableDictionary<NSNumber *, id> *g_list_icons;

CGImageRef j2me_ui_copy_list_icon(int index) {
    @synchronized ([NSMutableDictionary class]) {
        id value = g_list_icons[@(index)];
        return value ? (CGImageRef)CFBridgingRetain(value) : NULL;
    }
}
static int g_list_type = 0; // IMPLICIT=3, EXCLUSIVE=1, MULTIPLE=2

// Alert
static char g_alert_text[1024] = "";
static int g_alert_timeout = -2; // FOREVER

static j2me_ui_callback g_ui_callback = NULL;
static pthread_mutex_t g_screen_lock = PTHREAD_MUTEX_INITIALIZER;
static atomic_int g_screen_revision = 0;
int j2me_ui_revision(void) { return atomic_load(&g_screen_revision); }
void j2me_ui_lock_screen(void) { pthread_mutex_lock(&g_screen_lock); }
void j2me_ui_unlock_screen(void) { pthread_mutex_unlock(&g_screen_lock); }
static s32 n_lockScreen(Runtime *runtime, JClass *clazz) {
    jthread_block_enter(runtime);
    j2me_ui_lock_screen();
    jthread_block_exit(runtime);
    return RUNTIME_STATUS_NORMAL;
}
static s32 n_unlockScreen(Runtime *runtime, JClass *clazz) {
    j2me_ui_unlock_screen();
    return RUNTIME_STATUS_NORMAL;
}
static s32 n_screenRevision(Runtime *runtime, JClass *clazz) {
    push_int(runtime->stack, j2me_ui_revision());
    return RUNTIME_STATUS_NORMAL;
}
static NSMutableDictionary<NSNumber *, NSData *> *g_pending_text;

void j2me_ui_stage_text(int revision, int index, const uint16_t *units, int count) {
    if (index < 0 || index >= MAX_FORM_ITEMS || count < 0) return;
    @synchronized ([NSProcessInfo class]) {
        if (revision != j2me_ui_revision()) return;
        if (!g_pending_text) g_pending_text = [NSMutableDictionary dictionary];
        g_pending_text[@(index)] = count == 0 ? [NSData data] :
            [NSData dataWithBytes:units length:(NSUInteger)count * sizeof(uint16_t)];
    }
}

static s32 n_takeText(Runtime *runtime, JClass *clazz) {
    JniEnv *env = runtime->jnienv;
    int index = env->localvar_getInt(runtime->localvar, 0);
    NSData *data;
    @synchronized ([NSProcessInfo class]) {
        int revision = env->localvar_getInt(runtime->localvar, 1);
        data = nil;
        if (revision == j2me_ui_revision()) {
            data = g_pending_text[@(index)];
            [g_pending_text removeObjectForKey:@(index)];
        }
    }
    Instance *array = NULL;
    if (data) {
        array = jarray_create_by_type_index(runtime, (s32)(data.length / sizeof(uint16_t)), DATATYPE_JCHAR);
        if (array && data.length) memcpy(array->arr_body, data.bytes, data.length);
    }
    env->push_ref(runtime->stack, array);
    return RUNTIME_STATUS_NORMAL;
}

void j2me_ui_set_callback(j2me_ui_callback callback) {
    g_ui_callback = callback;
}

// ============================================================
// Public getters for Swift side
// ============================================================

const char *j2me_ui_get_form_title(void) { return g_form_title; }
int j2me_ui_get_form_item_count(void) { return g_form_item_count; }
int j2me_ui_get_form_item_type(int index) { return index < g_form_item_count ? g_form_items[index].type : -1; }
const char *j2me_ui_get_form_item_label(int index) { return index < g_form_item_count ? g_form_items[index].label : ""; }
const char *j2me_ui_get_form_item_text(int index) { return index < g_form_item_count ? g_form_items[index].text : ""; }
int j2me_ui_get_form_item_param2(int index) {
    return index >= 0 && index < g_form_item_count ? g_form_items[index].intParam2 : 0;
}
int j2me_ui_get_form_item_param1(int index) { return index < g_form_item_count ? g_form_items[index].intParam1 : 0; }

int j2me_ui_get_command_count(void) { return g_form_command_count; }
const char *j2me_ui_get_command_label(int index) { return index < g_form_command_count ? g_form_commands[index].label : ""; }
int j2me_ui_get_command_type(int index) { return index < g_form_command_count ? g_form_commands[index].type : 0; }
int j2me_ui_get_command_id(int index) { return index < g_form_command_count ? g_form_commands[index].id : -1; }

int j2me_ui_get_list_item_count(void) { return g_list_item_count; }
const char *j2me_ui_get_list_item(int index) { return index < g_list_item_count ? g_list_items[index] : ""; }
int j2me_ui_get_list_type(void) { return g_list_type; }

const char *j2me_ui_get_alert_text(void) { return g_alert_text; }
int j2me_ui_get_alert_timeout(void) { return g_alert_timeout; }

// ============================================================
// Native methods — called from Java to build UI
// ============================================================

static s32 n_formBegin(Runtime *runtime, JClass *clazz) {
    JniEnv *env = runtime->jnienv;
    Instance *jtitle = env->localvar_getRefer(runtime->localvar, 0);
    s32 type = env->localvar_getInt(runtime->localvar, 1);

    @synchronized ([NSProcessInfo class]) {
        atomic_fetch_add(&g_screen_revision, 1);
        [g_pending_text removeAllObjects];
    }
    g_choice_item = -1;
    [g_form_choices removeAllObjects];
    g_form_item_count = 0;
    g_form_command_count = 0;
    g_list_item_count = 0;
    @synchronized ([NSMutableDictionary class]) { [g_list_icons removeAllObjects]; }
    g_form_type = type;

    if (jtitle) {
        Utf8String *ustr = utf8_create();
        env->jstring_2_utf8(jtitle, ustr, runtime);
        strncpy(g_form_title, utf8_cstr(ustr), sizeof(g_form_title) - 1);
        utf8_destroy(ustr);
    } else {
        g_form_title[0] = '\0';
    }
    return RUNTIME_STATUS_NORMAL;
}

static s32 n_formAddStringItem(Runtime *runtime, JClass *clazz) {
    JniEnv *env = runtime->jnienv;
    Instance *jlabel = env->localvar_getRefer(runtime->localvar, 0);
    Instance *jtext = env->localvar_getRefer(runtime->localvar, 1);
    s32 appearance = env->localvar_getInt(runtime->localvar, 2);

    if (g_form_item_count >= MAX_FORM_ITEMS) return RUNTIME_STATUS_NORMAL;
    FormItem *item = &g_form_items[g_form_item_count++];
    item->type = 0; // string
    item->intParam1 = appearance;
    item->label[0] = '\0';
    item->text[0] = '\0';

    if (jlabel) {
        Utf8String *u = utf8_create();
        env->jstring_2_utf8(jlabel, u, runtime);
        strncpy(item->label, utf8_cstr(u), sizeof(item->label) - 1);
        utf8_destroy(u);
    }
    if (jtext) {
        Utf8String *u = utf8_create();
        env->jstring_2_utf8(jtext, u, runtime);
        strncpy(item->text, utf8_cstr(u), sizeof(item->text) - 1);
        utf8_destroy(u);
    }
    return RUNTIME_STATUS_NORMAL;
}

static s32 n_formAddTextField(Runtime *runtime, JClass *clazz) {
    JniEnv *env = runtime->jnienv;
    Instance *jlabel = env->localvar_getRefer(runtime->localvar, 0);
    Instance *jtext = env->localvar_getRefer(runtime->localvar, 1);
    s32 maxSize = env->localvar_getInt(runtime->localvar, 2);
    s32 constraints = env->localvar_getInt(runtime->localvar, 3);

    if (g_form_item_count >= MAX_FORM_ITEMS) return RUNTIME_STATUS_NORMAL;
    FormItem *item = &g_form_items[g_form_item_count++];
    item->type = 1; // textfield
    item->intParam1 = maxSize;
    item->intParam2 = constraints;
    item->label[0] = '\0';
    item->text[0] = '\0';

    if (jlabel) {
        Utf8String *u = utf8_create();
        env->jstring_2_utf8(jlabel, u, runtime);
        strncpy(item->label, utf8_cstr(u), sizeof(item->label) - 1);
        utf8_destroy(u);
    }
    if (jtext) {
        Utf8String *u = utf8_create();
        env->jstring_2_utf8(jtext, u, runtime);
        strncpy(item->text, utf8_cstr(u), sizeof(item->text) - 1);
        utf8_destroy(u);
    }
    return RUNTIME_STATUS_NORMAL;
}

static s32 n_formAddChoice(Runtime *runtime, JClass *clazz) {
    JniEnv *env = runtime->jnienv;
    g_choice_item = -1;
    if (g_form_item_count >= MAX_FORM_ITEMS) return RUNTIME_STATUS_NORMAL;
    g_choice_item = g_form_item_count++;
    FormItem *item = &g_form_items[g_choice_item];
    memset(item, 0, sizeof(*item));
    item->type = 2;
    item->intParam1 = env->localvar_getInt(runtime->localvar, 1);
    Instance *label = env->localvar_getRefer(runtime->localvar, 0);
    if (label) {
        Utf8String *u = utf8_create();
        env->jstring_2_utf8(label, u, runtime);
        strncpy(item->label, utf8_cstr(u), sizeof(item->label) - 1);
        utf8_destroy(u);
    }
    if (!g_form_choices) g_form_choices = [NSMutableDictionary dictionary];
    g_form_choices[@(g_choice_item)] = [NSMutableArray array];
    return RUNTIME_STATUS_NORMAL;
}

static s32 n_formAddChoiceOption(Runtime *runtime, JClass *clazz) {
    if (g_choice_item < 0) return RUNTIME_STATUS_NORMAL;
    JniEnv *env = runtime->jnienv;
    Instance *text = env->localvar_getRefer(runtime->localvar, 0);
    Utf8String *u = utf8_create();
    if (text) env->jstring_2_utf8(text, u, runtime);
    const char *value = utf8_cstr(u);
    if (!value) value = "";
    [g_form_choices[@(g_choice_item)] addObject:[NSData dataWithBytes:value length:strlen(value) + 1]];
    utf8_destroy(u);
    return RUNTIME_STATUS_NORMAL;
}

static s32 n_formAddCommand(Runtime *runtime, JClass *clazz) {
    JniEnv *env = runtime->jnienv;
    Instance *jlabel = env->localvar_getRefer(runtime->localvar, 0);
    s32 cmdType = env->localvar_getInt(runtime->localvar, 1);
    s32 priority = env->localvar_getInt(runtime->localvar, 2);
    s32 cmdId = env->localvar_getInt(runtime->localvar, 3);

    if (g_form_command_count >= MAX_COMMANDS) return RUNTIME_STATUS_NORMAL;
    FormCommand *cmd = &g_form_commands[g_form_command_count++];
    cmd->type = cmdType;
    cmd->priority = priority;
    cmd->id = cmdId;
    cmd->label[0] = '\0';

    if (jlabel) {
        Utf8String *u = utf8_create();
        env->jstring_2_utf8(jlabel, u, runtime);
        strncpy(cmd->label, utf8_cstr(u), sizeof(cmd->label) - 1);
        utf8_destroy(u);
    }
    return RUNTIME_STATUS_NORMAL;
}

static s32 n_formShow(Runtime *runtime, JClass *clazz) {
    printf("[J2ME UI] formShow: type=%d title='%s' items=%d commands=%d\n",
           g_form_type, g_form_title, g_form_item_count, g_form_command_count);
    if (g_ui_callback) {
        int action;
        switch (g_form_type) {
            case 0: action = J2ME_UI_ACTION_SHOW_FORM; break;
            case 1: action = J2ME_UI_ACTION_SHOW_LIST; break;
            case 2: action = J2ME_UI_ACTION_SHOW_ALERT; break;
            case 3: action = J2ME_UI_ACTION_SHOW_TEXTBOX; break;
            default: action = J2ME_UI_ACTION_SHOW_FORM; break;
        }
        g_ui_callback(action, j2me_ui_revision());
    }
    return RUNTIME_STATUS_NORMAL;
}

// Only deduplicate Canvas notices already applied by UIKit at this exact
// revision. Never suppress alerts, forms, new revisions, or game input.
static atomic_bool treo_ui_cut_enabled;
static _Atomic uint64_t treo_ui_canvas_applied_token, treo_ui_saved_notices;
void treo_afk_ui_cut_set(int enabled) {
    atomic_store(&treo_ui_cut_enabled, false);
    atomic_store(&treo_ui_canvas_applied_token, 0);
    if (enabled) atomic_store(&treo_ui_cut_enabled, true);
}
void treo_afk_ui_canvas_applied(int revision) {
    if (atomic_load(&treo_ui_cut_enabled))
        atomic_store(&treo_ui_canvas_applied_token, 1ULL + (uint32_t)revision);
}
uint64_t treo_afk_ui_notices_saved(void) { return atomic_load(&treo_ui_saved_notices); }

static s32 n_showCanvas(Runtime *runtime, JClass *clazz) {
    const int revision = j2me_ui_revision();
    if (atomic_load(&treo_ui_cut_enabled) &&
        atomic_load(&treo_ui_canvas_applied_token) == 1ULL + (uint32_t)revision) {
        atomic_fetch_add(&treo_ui_saved_notices, 1);
        return RUNTIME_STATUS_NORMAL;
    }
    printf("[J2ME UI] showCanvas\n");
    if (g_ui_callback) {
        g_ui_callback(J2ME_UI_ACTION_SHOW_CANVAS, revision);
    }
    return RUNTIME_STATUS_NORMAL;
}

static s32 n_listSetLastIcon(Runtime *runtime, JClass *clazz) {
    if (g_list_item_count <= 0) return RUNTIME_STATUS_NORMAL;
    JniEnv *env = runtime->jnienv;
    s64 handle = env->localvar_getLong_2slot(runtime->localvar, 0);
    CGImageRef icon = j2me_render_copy_image(handle);
    if (icon) {
        @synchronized ([NSMutableDictionary class]) {
            if (!g_list_icons) g_list_icons = [NSMutableDictionary dictionary];
            g_list_icons[@(g_list_item_count - 1)] = CFBridgingRelease(icon);
        }
    }
    return RUNTIME_STATUS_NORMAL;
}

static s32 n_listAddItem(Runtime *runtime, JClass *clazz) {
    JniEnv *env = runtime->jnienv;
    Instance *jtext = env->localvar_getRefer(runtime->localvar, 0);

    if (g_list_item_count >= MAX_FORM_ITEMS) return RUNTIME_STATUS_NORMAL;
    g_list_items[g_list_item_count][0] = '\0';
    if (jtext) {
        Utf8String *u = utf8_create();
        env->jstring_2_utf8(jtext, u, runtime);
        strncpy(g_list_items[g_list_item_count], utf8_cstr(u), 255);
        utf8_destroy(u);
    }
    g_list_item_count++;
    return RUNTIME_STATUS_NORMAL;
}

static s32 n_setListType(Runtime *runtime, JClass *clazz) {
    JniEnv *env = runtime->jnienv;
    g_list_type = env->localvar_getInt(runtime->localvar, 0);
    return RUNTIME_STATUS_NORMAL;
}

static s32 n_setAlertText(Runtime *runtime, JClass *clazz) {
    JniEnv *env = runtime->jnienv;
    Instance *jtext = env->localvar_getRefer(runtime->localvar, 0);
    s32 timeout = env->localvar_getInt(runtime->localvar, 1);
    g_alert_timeout = timeout;
    g_alert_text[0] = '\0';
    if (jtext) {
        Utf8String *u = utf8_create();
        env->jstring_2_utf8(jtext, u, runtime);
        strncpy(g_alert_text, utf8_cstr(u), sizeof(g_alert_text) - 1);
        utf8_destroy(u);
    }
    return RUNTIME_STATUS_NORMAL;
}

// --- platformRequest: open URL in system browser ---

static s32 n_platformRequest(Runtime *runtime, JClass *clazz) {
    JniEnv *env = runtime->jnienv;
    Instance *jurl = env->localvar_getRefer(runtime->localvar, 0);
    if (!jurl) return RUNTIME_STATUS_NORMAL;

    Utf8String *u = utf8_create();
    env->jstring_2_utf8(jurl, u, runtime);
    const char *urlStr = utf8_cstr(u);

    dispatch_async(dispatch_get_main_queue(), ^{
        NSURL *url = [NSURL URLWithString:[NSString stringWithUTF8String:urlStr]];
        if (url) {
            [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:nil];
        }
    });

    utf8_destroy(u);
    return RUNTIME_STATUS_NORMAL;
}

// ============================================================
// Native method table
// ============================================================

// No network data, URLs, credentials, or timing loop. Called only when
// Java ME Connector/stream state advances during a connection attempt.
static s32 n_netTraceStage(Runtime *runtime, JClass *clazz) {
    const int stage = localvar_getInt(runtime->localvar, 0);
    const char *label = NULL;
    switch (stage) {
        case 1: label = "socket_dispatch"; break;
        case 2: label = "socket_construct_begin"; break;
        case 3: label = "socket_construct_ready"; break;
        case 4: label = "socket_dispatch_ready"; break;
        case 5: label = "socket_data_output_begin"; break;
        case 6: label = "socket_data_output_ready"; break;
        case 7: label = "socket_data_input_begin"; break;
        case 8: label = "socket_data_input_ready"; break;
        case 9: label = "socket_dispatch_io_failure"; break;
        case 10: label = "http_dispatch"; break;
        case 11: label = "http_handler_ready"; break;
        case 12: label = "http_dispatch_io_failure"; break;
        default: break;
    }
    if (label) {
        char event[96];
        snprintf(event, sizeof(event), "api_stage:%s", label);
        jvm_bridge_note_net_trace(event);
    }
    return RUNTIME_STATUS_NORMAL;
}

#define CLS "javax/microedition/lcdui/NativeBridge"

static java_native_method j2me_ui_methods[] = {
    {CLS, "netTraceStage", "(I)V", n_netTraceStage},
    {CLS, "takeText", "(II)[C", n_takeText},
    {CLS, "lockScreen", "()V", n_lockScreen},
    {CLS, "unlockScreen", "()V", n_unlockScreen},
    {CLS, "screenRevision", "()I", n_screenRevision},
    {CLS, "formBegin",        "(Ljava/lang/String;I)V",                          n_formBegin},
    {CLS, "formAddStringItem","(Ljava/lang/String;Ljava/lang/String;I)V",        n_formAddStringItem},
    {CLS, "formAddTextField", "(Ljava/lang/String;Ljava/lang/String;II)V",       n_formAddTextField},
    {CLS, "formAddChoice", "(Ljava/lang/String;I)V", n_formAddChoice},
    {CLS, "formAddChoiceOption", "(Ljava/lang/String;)V", n_formAddChoiceOption},
    {CLS, "formAddCommand",   "(Ljava/lang/String;III)V",                        n_formAddCommand},
    {CLS, "formShow",         "()V",                                             n_formShow},
    {CLS, "showCanvas",       "()V",                                             n_showCanvas},
    {CLS, "listSetLastIcon", "(J)V", n_listSetLastIcon},
    {CLS, "listAddItem",      "(Ljava/lang/String;)V",                           n_listAddItem},
    {CLS, "setListType",      "(I)V",                                            n_setListType},
    {CLS, "setAlertText",     "(Ljava/lang/String;I)V",                          n_setAlertText},
    {CLS, "platformRequest",  "(Ljava/lang/String;)V",                           n_platformRequest},
};

#undef CLS

void j2me_ui_reg_natives(MiniJVM *jvm) {
    native_reg_lib(jvm, j2me_ui_methods,
                   sizeof(j2me_ui_methods) / sizeof(java_native_method));
    printf("[J2ME UI] Registered %lu native methods\n",
           sizeof(j2me_ui_methods) / sizeof(java_native_method));
}
