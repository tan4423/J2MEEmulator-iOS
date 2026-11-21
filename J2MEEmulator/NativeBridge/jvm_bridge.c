#include "jvm_bridge.h"
#include "jvm.h"
#include "jvm_util.h"
#include "garbage.h"
#include "j2me_render.h"
#include "j2me_input.h"
#include "j2me_ui.h"
#include "j2me_audio.h"
#include "j2me_micro3d_gl.h"
#include "m3g/j2me_m3g.h"
#include <stdio.h>
#include <string.h>
#include <stdatomic.h>
#if defined(TREO_IOS_GAME_JIT) && __JVM_OS_IOS__ && !defined(TREO_NINJA_DEEP_DISABLED)
#include "miniz.h"
#endif

static atomic_int treo_exact_ninja_verified;
int treo_ninja_deep_verified(void) {
    return atomic_load_explicit(&treo_exact_ninja_verified, memory_order_acquire);
}
#if defined(TREO_IOS_GAME_JIT) && __JVM_OS_IOS__ && !defined(TREO_NINJA_DEEP_DISABLED)
/*
 * NSO-family identification is based on stable game resource layout, not
 * exact JAR hashes or obfuscated class names. The separate runtime Canvas
 * bytecode-shape guard prevents a similar asset bundle with different paint
 * behavior from blindly inheriting this optimization.
 *
 * One archive read at MIDlet load; no ZIP or disk work in the Treo hot loop.
 */
static int treo_is_nso_family(const char *jar_path) {
    static const char *const resources[] = {
        "font/number",
        "font/tahoma_7",
        "map/1",
        "map/newmap",
        "x1/bg/bg00.png",
        "x1/export/0",
        "x1/e/d00.png"
    };
    if (!jar_path) return 0;
    mz_zip_archive archive = {0};
    if (!mz_zip_reader_init_file(&archive, jar_path, 0)) return 0;
    int match = 1;
    for (unsigned i = 0; i < sizeof(resources) / sizeof(resources[0]); ++i) {
        int index = mz_zip_reader_locate_file(
            &archive, resources[i], NULL, MZ_ZIP_FLAG_CASE_SENSITIVE);
        mz_zip_archive_file_stat file_stat;
        if (index < 0 || !mz_zip_reader_file_stat(&archive, index, &file_stat) ||
            file_stat.m_uncomp_size == 0 || mz_zip_reader_is_file_a_directory(&archive, index)) {
            match = 0;
            break;
        }
    }
    mz_zip_reader_end(&archive);
    return match;
}

#endif


static MiniJVM *g_jvm = NULL;
static atomic_int g_jvm_stop_requested = 0;

/* 3D supersampling scale — shared by M3G (reads directly) and MC3D (via system property) */
int g_render_3d_scale = 1;

int jvm_bridge_init(const char *res_root, const char *save_root, const char *midlet_jar,
                    int screen_width, int screen_height, int render_3d_scale,
                    int fps_limit) {
    if (g_jvm) {
        printf("[JVM Bridge] JVM already initialized\n");
        return -1;
    }
    atomic_store_explicit(&treo_exact_ninja_verified, 0, memory_order_release);
#if defined(TREO_IOS_GAME_JIT) && __JVM_OS_IOS__ && !defined(TREO_NINJA_DEEP_DISABLED)
    int ninja_match = treo_is_nso_family(midlet_jar);
    atomic_store_explicit(&treo_exact_ninja_verified, ninja_match, memory_order_release);
    printf("[JarBoxVM][NinjaDeep] profile=%s (NSO resource family)\n",
           ninja_match ? "matched" : "generic");
#endif
    // Note: g_jvm_stop_requested is NOT reset here — it is reset in
    // jvm_bridge_destroy() after the previous session.  Resetting it here
    // would race with backTapped() which may have already set the flag
    // before this function runs on the background thread.

    // Build bootclasspath: minijvm_rt.jar
    char bootclasspath[1024];
    snprintf(bootclasspath, sizeof(bootclasspath), "%s/minijvm_rt.jar", res_root);

    // Build classpath: j2me_api.jar + midlet JAR
    char classpath[4096];
    snprintf(classpath, sizeof(classpath), "%s/j2me_api.jar:%s",
             res_root, midlet_jar);

    printf("[JVM Bridge] bootclasspath: %s\n", bootclasspath);
    printf("[JVM Bridge] classpath: %s\n", classpath);

    // Create JVM instance
    g_jvm = jvm_create();
    if (!g_jvm) {
        printf("[JVM Bridge] ERROR: jvm_create() failed\n");
        return -2;
    }

    g_jvm->jdwp_enable = 0;
    g_jvm->jdwp_suspend_on_start = 0;
    g_jvm->max_heap_size = 128 * 1024 * 1024;       // 128MB (java + native via g_native_extra_heap)
    g_jvm->garbage_collect_period_ms = 500;          // GC every 0.5 sec
    g_jvm->heap_overload_percent = 70;               // GC at 70% heap

    s32 ret = jvm_init(g_jvm, (c8 *)bootclasspath, (c8 *)classpath);
    if (ret) {
        printf("[JVM Bridge] ERROR: jvm_init() failed with code %d\n", ret);
        jvm_destroy(g_jvm);
        g_jvm = NULL;
        atomic_store_explicit(&treo_exact_ninja_verified, 0, memory_order_release);
        return -3;
    }

    // Register native methods
    j2me_render_reg_natives(g_jvm);
    j2me_input_reg_natives(g_jvm);
    j2me_ui_reg_natives(g_jvm);
    j2me_audio_reg_natives(g_jvm);
    j2me_micro3d_gl_reg_natives(g_jvm);
    j2me_m3g_reg_natives(g_jvm);

    // Set system properties
    sys_properties_set_c(g_jvm, "os.name", "iOS");
    sys_properties_set_c(g_jvm, "app.save.root", save_root);
    sys_properties_set_c(g_jvm, "microedition.platform", "Apple/iPhone");
    sys_properties_set_c(g_jvm, "microedition.encoding", "UTF-8");
    sys_properties_set_c(g_jvm, "microedition.locale", "en");
    sys_properties_set_c(g_jvm, "microedition.profiles", "MIDP-2.0");
    sys_properties_set_c(g_jvm, "microedition.configuration", "CLDC-1.1");

    // Screen dimensions — used by Display.java to set canvas size
    char sw[16], sh[16];
    snprintf(sw, sizeof(sw), "%d", screen_width);
    snprintf(sh, sizeof(sh), "%d", screen_height);
    sys_properties_set_c(g_jvm, "j2me.screen.width", sw);
    sys_properties_set_c(g_jvm, "j2me.screen.height", sh);

    // 3D supersampling scale for M3G and MascotCapsule (1=native, 2=2x AA, 3=3x AA)
    g_render_3d_scale = render_3d_scale > 0 ? render_3d_scale : 1;
    char ss[8];
    snprintf(ss, sizeof(ss), "%d", g_render_3d_scale);
    sys_properties_set_c(g_jvm, "micro3d.v3.fbo.scale", ss);  // MC3D reads this in Render.java

    // FPS limit (0 = unlimited)
    if (fps_limit > 0) {
        char fl[8];
        snprintf(fl, sizeof(fl), "%d", fps_limit);
        sys_properties_set_c(g_jvm, "j2me.fps.limit", fl);
    }
    printf("[JVM Bridge] Screen size: %dx%d, 3D render scale: %s, FPS limit: %d\n",
           screen_width, screen_height, ss, fps_limit);

    printf("[JVM Bridge] JVM initialized successfully\n");
    return 0;
}

int jvm_bridge_run_midlet(const char *midlet_jar_path) {
    if (!g_jvm) {
        printf("[JVM Bridge] ERROR: JVM not initialized\n");
        return -1;
    }

    printf("[JVM Bridge] Running MIDlet from: %s\n", midlet_jar_path);

    ArrayList *java_para = arraylist_create(0);
    arraylist_push_back(java_para, (void *)midlet_jar_path);

    s32 ret = call_main(g_jvm, (c8 *)"javax/microedition/shell/MIDletRunner", java_para);

    arraylist_destroy(java_para);

    printf("[JVM Bridge] MIDlet finished with code %d\n", ret);
    return ret;
}

void jvm_bridge_destroy(void) {
    if (g_jvm) {
        printf("[JVM Bridge] Destroying JVM\n");

        // Step 1: Stop render subsystem first — zombie threads calling native
        // render methods will get NULL from acquire and return harmlessly.
        j2me_render_stop();

        // Step 2: Signal JVM shutdown and stop all threads.
        // exit_flag makes jvm_destroy's non-daemon wait loop exit immediately;
        // thread_stop_all sets is_stop/is_interrupt on each thread.
        g_jvm->collector->exit_flag = 1;
        thread_stop_all(g_jvm);

        // Step 3: jvm_destroy waits up to 3s for threads, then force-zombies.
        // After this, threads either exited or are zombie (status only — pthread
        // may still be running but render_stop prevents them touching freed resources).
        // Note: force-zombied pthreads may still execute briefly — class_clinit
        // and print_exception have is_stop / jvm_state guards to avoid crashes.
        jvm_destroy(g_jvm);
        g_jvm = NULL;

        // Step 4: Clean up native subsystems — safe because:
        // - render_stop blocks all render acquire calls
        // - jvm_destroy gave threads 3s to exit
        j2me_input_reset();
        j2me_audio_stop_all();
        j2me_micro3d_gl_cleanup();
        j2me_m3g_cleanup();
        j2me_render_cleanup(); // also resets render_stopped flag
        atomic_store(&g_jvm_stop_requested, 0);
        atomic_store_explicit(&treo_exact_ninja_verified, 0, memory_order_release);

        printf("[JVM Bridge] JVM destroyed, native state cleaned up\n");
    }
}

void jvm_bridge_request_stop(void) {
    printf("[JVM Bridge] Stop requested\n");
    atomic_store(&g_jvm_stop_requested, 1);
    j2me_display_wake();
}

int jvm_bridge_is_stop_requested(void) {
    return atomic_load(&g_jvm_stop_requested);
}
