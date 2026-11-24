#!/usr/bin/env python3
"""Non-deceptive Multi-JVM isolation gate for JarBox.

Reports which independently-owned native subsystems exist in this checkout.
This is a *source-shape* audit, not an iPhone concurrency or memory-safety
test. Do not unlock multiple active JVMs merely because one subsystem passes.
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
FILES = {
    "lifecycle": "J2MEEmulator/NativeBridge/jvm_bridge.c",
    "input": "J2MEEmulator/NativeBridge/j2me_input.c",
    "audio": "J2MEEmulator/NativeBridge/j2me_audio.m",
    "render": "J2MEEmulator/NativeBridge/j2me_render.m",
    "lcd_ui": "J2MEEmulator/NativeBridge/j2me_ui.m",
    "gc": "J2MEEmulator/minijvm/jvm/garbage.c",
    "runtime": "J2MEEmulator/minijvm/jvm/runtime.c",
    "input_runtime": "J2MEEmulator/NativeBridge/j2me_input.c",
    "vm_jvm": "J2MEEmulator/minijvm/jvm/jvm.h",
    "vm": "J2MEEmulator/minijvm/jvm/jvm.h",
    "session": "J2MEEmulator/minijvm/jvm/jarbox_session.h",
    "3d": "J2MEEmulator/NativeBridge/jvm_bridge.c",
}


def audit(root=ROOT):
    src = {label: (root / path).read_text(encoding="utf-8")
           for label, path in FILES.items()}
    lifecycle = ("typedef struct {" in src["lifecycle"]
                 and "JarBoxVMContext" in src["lifecycle"]
                 and "g_bridge_slots[JARBOX_REGISTRY_MAX_SLOTS]" in src["lifecycle"]
                 and "bridge_claim_worker_locked" in src["lifecycle"]
                 and "slot->stop_requested" in src["lifecycle"]
                 and "jvm_bridge_is_stop_requested_for_vm" in src["lifecycle"])
    input_owned = all(x in src["input"] for x in (
        "JarBoxInputRing ring;", "context_for_runtime(runtime)",
        "j2me_input_binding_generation", "j2me_input_release_vm"))
    audio_owned = all(x in src["audio"] for x in (
        "g_audio_owners", "g_midi_owners",
        "j2me_audio_stop_for_vm(MiniJVM *vm)",
        "audio_owned_by_vm(runtime->jvm", "j2me_input_post_key_to_vm"))
    runtime_generation_owned = (
        "uint64_t jarbox_native_generation;" in src["vm_jvm"]
        and "runtime->thrd_info->jarbox_native_generation" in src["runtime"]
        and "jarbox_native_heap_key_for_runtime(runtime)" in src["render"]
        and "jarbox_native_heap_key_for_runtime(runtime)" in src["lcd_ui"]
        and "context_for_runtime(runtime)" in src["input_runtime"]
        and '#include "garbage.h"' in src["input_runtime"])
    native_heap_owned = all(x in src["gc"] for x in (
        "jarbox_native_heap_register_vm(MiniJVM *jvm)",
        "jarbox_native_heap_for_vm(collector->jvm)",
        "slot->key == key")) and all(x in src["render"] for x in (
        "uint64_t heap_key;", "jarbox_native_heap_key_for_vm(owner)",
        "native_heap_sub(rc->heap_key, pixels)"))
    treo_gc_owned = ("JarBoxTreoState treo_state;" in src["session"]
                     and "JarBoxSession *session;" in src["vm"]
                     and "jarbox_treo_smart_period(&jvm->session->treo_state)" in src["gc"]
                     and "jarbox_treo_probe_period(&jvm->session->treo_state)" in src["gc"]
                     and "jvm_bridge_visit_running_vm" in src["gc"]
                     and "treo_apply_mode_locked(vm, change->mode, change->now_ns);" in src["render"]
                      and "jarbox_treo_smart_set(state, mode == 8);" in src["render"])
    ui_owned = all(x in src["lcd_ui"] for x in (
        "JarBoxUIScreenContext", "ui_slot_for_vm(vm)",
        "j2me_ui_release_vm(MiniJVM *vm)",
        "j2me_ui_focus_vm(MiniJVM *vm)",
        "g_ui_thread_key = valid ? key : 0;",
        "jarbox_ui_generation_matches(key, slot_key)",
    ))
    blockers = {
        "render_single_flush_callback":
            "static j2me_flush_callback g_flush_callback" in src["render"],
        "render_global_stop_and_cleanup":
            "void j2me_render_stop(void)" in src["render"]
            and "atomic_store_explicit(&g_render_stopped, 1, memory_order_release)" in src["render"]
            and "void j2me_render_cleanup(void)" in src["render"]
            and "g_live_rc_count = 0" in src["render"].rsplit(
                "void j2me_render_cleanup(void) {", 1)[-1]
            and "g_live_img_count = 0" in src["render"].rsplit(
                "void j2me_render_cleanup(void) {", 1)[-1],
        "render_global_haptic_teardown":
            "g_hapticEngine stopWithCompletionHandler" in src["render"],
        "render_global_stop_barrier":
            "atomic_store_explicit(&g_render_stopped, 1, memory_order_release)" in src["render"]
            and "static _Atomic int g_render_stopped = 0" in src["render"],
        # Device/queue/vertex buffers remain shared but serialized. Per-owner
        # render targets and texture caches alone are not proof of full isolation.
        "render_shared_metal_workspace":
            "static id<MTLCommandQueue> treo_live_queue" in src["render"]
            and "static id<MTLBuffer> treo_live_vertices" in src["render"],
        "render_raw_unscoped_handle_acquire":
            "RenderContext *rc = (RenderContext *)(intptr_t)handle;" in src["render"]
            and "RenderImage *img = (RenderImage *)(intptr_t)handle;" in src["render"],
        "lcd_ui_single_form_state":
            "static char g_form_title" in src["lcd_ui"],
        "lcd_ui_single_callback":
            "static j2me_ui_callback g_ui_callback" in src["lcd_ui"],
        "treo_single_global_mode":
            "_Atomic int treo_afk_mode" in src["render"],
        "gc_single_native_memory_account":
            "s64 g_native_extra_heap = 0" in src["gc"],
        "gc_single_smart_treo_scheduler":
            "static int treo_gc_smart_enabled, treo_gc_smart_fallback" in src["gc"],
        # The legacy M3G cleanup destroys process-wide engine resources.
        # Stopping a 2D session must not tear down another session's 3D state.
        "3d_global_m3g_cleanup":
            "j2me_m3g_cleanup();" in src["3d"],
        "3d_single_supersampling":
            "int g_render_3d_scale = 1" in src["3d"],
    }
    # This gate must stay on while the above shared mutable state exists.
    one_vm_gate = ("int jvm_bridge_supported_concurrent_sessions(void) {\n    return 1;"
                   in src["lifecycle"]
                   and "bridge_reserve_slot_locked(" in src["lifecycle"]
                   and "(unsigned)jvm_bridge_supported_concurrent_sessions()" in src["lifecycle"])
    # A source-shape gate may only block unsafe concurrency; it cannot certify
    # thread safety or device behavior. All known owned components must pass,
    # all shared-state blockers must disappear, and the single-VM guard must
    # remain until an independent runtime/device validation changes this gate.
    owned = {
        "vm_lifecycle": bool(lifecycle),
        "input_queue_display_wait": bool(input_owned),
        "wav_midi_players": bool(audio_owned),
        "lcd_ui_screen_buffers": bool(ui_owned),
        "gc_native_graphics_accounting": bool(native_heap_owned),
        "java_runtime_generation": bool(runtime_generation_owned),
        "treo_gc_afk_state": bool(treo_gc_owned),
    }
    source_prerequisites_met = all(owned.values()) and not any(blockers.values())
    ready = source_prerequisites_met and not one_vm_gate
    # No automated source scan proves safe concurrent execution on iOS.
    # Require a separately reviewed runtime/device validation before enabling.
    runtime_device_validated = False
    ready = ready and runtime_device_validated
    return {
        "schema": "jarbox-multivm-readiness-v1",
        "concurrent_jvms_safe_to_enable": bool(ready),
        "enforced_single_active_jvm": bool(one_vm_gate),
        "verified_source_structure_only": True,
        "runtime_device_concurrency_validated": runtime_device_validated,
        "owned_native_components": owned,
        "source_prerequisites_met": source_prerequisites_met,
        "unisolated_native_blockers": {
            name: found for name, found in sorted(blockers.items()) if found
        },
        "notes": [
            "Input contexts (capacity four) are not four working JVM sessions.",
            "2D handles and AFK raster modes are keyed by generation; Metal targets/caches are per owner but GPU queue, UIKit destination and haptic engine remain shared.",
            "LCDUI slot bindings, Form/List buffers and queued URL actions now check VM generation; UIKit controller registration remains process-wide.",
            "MIDP List icons and ordinary 2D Canvas/Image acquire paths now validate JVM generation; live handle address reuse after a zombie thread and VM pointer reuse still require lifetime binding.",
            "Smart GC/probe, NSO signature, Canvas auto-fallback and 2D AFK mode are per session; JAR diagnostic worker, Metal replay and process-level renderer configuration remain shared.",
            "Java thread roots snapshot native generation; nested Runtime frames share it. Render, LCDUI and Display Input reject stale runtime generations after pointer reuse.",
            "M3G global engine cleanup remains a blocker independent of MascotCapsule generation ownership.",
            "Network, classloader, JIT, sockets, native image handles, and teardown still need device validation.",
            "Do not enable another JVM while there are unisolated native blockers.",
        ],
    }


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--json", action="store_true",
                    help="Machine-readable JSON (also default output)")
    ap.add_argument("--require-ready", action="store_true",
                    help="Exit nonzero when true multi-JVM safety is not established")
    args = ap.parse_args(argv)
    result = audit()
    print(json.dumps(result, ensure_ascii=False, indent=2, sort_keys=True))
    return 0 if not args.require_ready or result["concurrent_jvms_safe_to_enable"] else 2


if __name__ == "__main__":
    raise SystemExit(main())
