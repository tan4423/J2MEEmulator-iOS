"""Compile the *actual* native header and stress one-visible/rest-parked policy.

This checks policy semantics only: a real app still needs the native
multi-session executor and VM-specific Treo/render/GC to be isolated.
"""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
HEADER = ROOT / "J2MEEmulator/NativeBridge/jarbox_focus_policy.h"
BRIDGE = ROOT / "J2MEEmulator/NativeBridge/jvm_bridge.c"
GAME = ROOT / "J2MEEmulator/UI/GameViewController.swift"

SOURCE = r"""
#include "jarbox_focus_policy.h"
#include <pthread.h>
#include <sched.h>
#include <stdint.h>
#include <stdlib.h>
#include <stdio.h>
typedef struct { JarBoxFocusPolicy *policy; uint64_t token; int count; } Worker;
static void *switcher(void *opaque) {
    Worker *w = opaque;
    for (int i = 0; i < w->count; ++i) {
        if (!jarbox_focus_select(w->policy, w->token)) return (void*)1;
        if ((i & 15) == 0) sched_yield();
    }
    return NULL;
}
static int invariant(JarBoxFocusPolicy *p) {
    pthread_mutex_lock(&p->mutex);
    int foreground = 0, live = 0;
    for (int i = 0; i < JARBOX_FOCUS_MAX_SESSIONS; ++i) {
        JarBoxFocusEntry *e = &p->entries[i];
        if (!e->live) continue;
        ++live;
        if (!e->parked) {
            ++foreground;
            if (e->token != p->visible_token) {
                pthread_mutex_unlock(&p->mutex); return 0;
            }
        }
    }
    const int ok = foreground <= 1 &&
        (!p->visible_token ? foreground == 0 : foreground == 1) &&
        live <= JARBOX_FOCUS_MAX_SESSIONS;
    pthread_mutex_unlock(&p->mutex);
    return ok;
}
int main(void) {
    JarBoxFocusPolicy policy = JARBOX_FOCUS_POLICY_INITIALIZER;
    if (!jarbox_focus_register(&policy, 101) ||
        !jarbox_focus_register(&policy, 102) ||
        !jarbox_focus_register(&policy, 103)) return 1;
    if (!invariant(&policy) || jarbox_focus_live_count(&policy) != 3 ||
        jarbox_focus_visible(&policy) != 0) return 2;
    if (!jarbox_focus_select(&policy, 101) ||
        jarbox_focus_is_parked(&policy, 101) != 0 ||
        jarbox_focus_is_parked(&policy, 102) != 1 ||
        jarbox_focus_is_parked(&policy, 103) != 1) return 3;
    if (jarbox_focus_register(&policy, 101)) return 4; /* no duplicate */
    if (jarbox_focus_select(&policy, 999)) return 5; /* no phantom */
    if (jarbox_focus_visible(&policy) != 101) return 6;
    // Parking a hidden tab must leave the foreground tab selected.
    if (!jarbox_focus_park_one(&policy, 102) ||
        jarbox_focus_park_one(&policy, 999) ||
        jarbox_focus_visible(&policy) != 101 ||
        jarbox_focus_is_parked(&policy, 101) != 0 ||
        !invariant(&policy)) return 17;
    if (!jarbox_focus_park_one(&policy, 101) ||
        jarbox_focus_visible(&policy) ||
        jarbox_focus_is_parked(&policy, 101) != 1 ||
        !jarbox_focus_select(&policy, 101)) return 18;
    pthread_t threads[3];
    Worker workers[3] = {
        {&policy,101,10000}, {&policy,102,10000}, {&policy,103,10000}
    };
    for (int i=0;i<3;i++)
        if (pthread_create(&threads[i],NULL,switcher,&workers[i])) return 7;
    for (int i=0;i<3;i++) {
        void *ret=NULL;
        pthread_join(threads[i],&ret);
        if (ret) return 8;
    }
    if (!invariant(&policy)) return 9;
    jarbox_focus_park_all(&policy);
    if (!invariant(&policy) || jarbox_focus_visible(&policy) ||
        jarbox_focus_is_parked(&policy, 101) != 1 ||
        jarbox_focus_is_parked(&policy, 102) != 1 ||
        jarbox_focus_is_parked(&policy, 103) != 1) return 10;
    if (!jarbox_focus_select(&policy, 102) || !invariant(&policy)) return 11;
    if (!jarbox_focus_unregister(&policy, 102) ||
        jarbox_focus_visible(&policy) ||
        jarbox_focus_is_parked(&policy, 101) != 1 ||
        jarbox_focus_is_parked(&policy, 103) != 1 ||
        jarbox_focus_live_count(&policy) != 2) return 12;
    if (jarbox_focus_unregister(&policy, 102)) return 13;
    if (!jarbox_focus_select(&policy, 103) || !invariant(&policy)) return 14;
    jarbox_focus_unregister(&policy, 101);
    if (jarbox_focus_visible(&policy) != 103 ||
        jarbox_focus_is_parked(&policy, 103) != 0) return 15;
    jarbox_focus_unregister(&policy, 103);
    if (jarbox_focus_live_count(&policy) || jarbox_focus_visible(&policy)) return 16;
    return 0;
}
"""


class MultiVMFocusPolicyTest(unittest.TestCase):
    def test_real_native_single_visible_rest_parked(self):
        cc = shutil.which("cc") or shutil.which("clang")
        if not cc:
            self.skipTest("No host C compiler")
        with tempfile.TemporaryDirectory(prefix="jarbox-focus-test-") as temp:
            directory = Path(temp)
            src, binary = directory / "policy.c", directory / "policy"
            src.write_text(SOURCE, encoding="utf-8")
            subprocess.run(
                [cc, "-std=c11", "-O2", "-Wall", "-Wextra", "-Werror",
                 "-pthread", "-I", str(HEADER.parent),
                 str(src), "-o", str(binary)],
                check=True, capture_output=True, text=True, timeout=45)
            subprocess.run([str(binary)], check=True, timeout=20,
                           capture_output=True, text=True)

    def test_back_libraries_are_parked_and_resumed_by_same_token(self):
        source = BRIDGE.read_text(encoding="utf-8")
        game = GAME.read_text(encoding="utf-8")
        self.assertIn("JarBoxFocusPolicy g_bridge_focus", source)
        self.assertIn("jvm_bridge_park_session(uint64_t token)", source)
        self.assertIn("jvm_bridge_focus_session(uint64_t token)", source)
        # No use-after-free when STOPPING races with a UIKit focus/park.
        self.assertIn("static MiniJVM *bridge_pin_running_owner(uint64_t token", source)
        self.assertIn("jarbox_registry_pin_vm(&g_bridge_registry, token, held)", source)
        self.assertIn("jarbox_session_callback_done(held);", source)
        self.assertIn("jarbox_registry_contains_token(&g_bridge_registry, token)", source)
        self.assertIn("jarbox_focus_park_one(&g_bridge_focus, token)", source)
        self.assertNotIn("jarbox_focus_park_all(&g_bridge_focus)", source)
        self.assertIn("j2me_render_focus_vm(owner)", source)
        self.assertIn("j2me_input_focus_vm(owner)", source)
        self.assertIn("j2me_ui_focus_vm(owner)", source)
        self.assertIn("jarbox_registry_finish(&g_bridge_registry, &g_bridge_focus", source)
        self.assertIn("jvm_bridge_park_session(gameSessionToken)", game)
        self.assertIn("jvm_bridge_focus_session(self.gameSessionToken)", game)
        # Existing Treo-8 path must not be replaced by an inefficient fake.
        self.assertIn("treo_park_begin_for_token(gameSessionToken,", game)
        self.assertIn("treo_park_end_for_token(gameSessionToken)", game)
        # Never unlock a second VM while global rendering/Treo persists.
        self.assertIn("bridge_reserve_slot_locked(", source)
        self.assertIn("int jvm_bridge_supported_concurrent_sessions(void) {\n    return 2;", source)


if __name__ == "__main__":
    unittest.main()
