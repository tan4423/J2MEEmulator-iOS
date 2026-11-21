# JarBox Treo: deliberate center-button wake and no-timer thermal report

Candidate UI checkpoint: `36f0eeab255e01230789770a5201c91f1cfa8a02` on `loader-ios-jit-probe`. Not yet verified by iOS compilation or device testing. The previously iPhone-confirmed springboard animation fix `faaddc859943d52aa1ad040ded3058ba32afa61a` remains untouched.

## Touch behavior

Before this change, `showBlackout()` attached `hideBlackout` to the *entire screen* UIButton. A tap or finger release could wake the game anywhere. The full-screen black cover continues to swallow all touches and blocks input to Java; now **only** the centered, 72×72-point circular wake button has `.touchUpInside` connected to `hideBlackout`. A drag starting outside the button, corner taps, and taps on the caption must not end Treo. No new animation, timer, Java hook or drawing. VoiceOver has a dedicated accessible wake button.

**Exception by design:** iOS `UIApplication.willResignActiveNotification` still ends blackout to restore brightness and GC policy when the app loses foreground activity. This is not a touch-triggered exit.

## Metrics

`[JarBoxVM][Treo]` already computes whole-session **app and main CPU averages**, Java paint CPU/s, paint/s, GC, and springboard motion from native cumulative counters. This change appends:
- `thermal_start`, `thermal_end`: `ProcessInfo.processInfo.thermalState` at start/end of Treo.
- `thermal_peak`: highest observed OS thermal category from start, state-change notifications and end.
- `thermal_changes`: number of delivered state-change notifications during Treo.

Apple's values `nominal`, `fair`, `serious`, `critical` represent **coarse device-wide thermal pressure**, NOT degrees Celsius or measured battery/chip temperature. An app cannot present Celsius here. Charge status, ambient heat and unrelated processes may affect thermal state. Read the initial state *before* subscribing to the notification, per Apple. Remove observer on Treo exit and view-controller deinit. No repeated timer or additional CPU sampling, so overhead is negligible relative to Java VM work and CPU figures remain whole-session averages, not real-time per-second peaks.

## Build and test: no code edits or environment variables required

1. Codemagic: select branch `loader-ios-jit-probe`, workflow **`J2ME Treo JIT probe unsigned`**, then Start new build. Both `paint_sampler=off` and `utf16_fast=on` are already configured. Install the unsigned IPA using the same device method used for prior tests. **A build started before commit `36f0eea` does not contain the new wake/thermal feature.**
2. Open the same Ninja JAR and same gameplay state; turn Ninja's own Java Treo OFF. In JarBox menu tap **Treo tiết kiệm**.
3. Tap screen corners and swipe around the screen without beginning on the center icon. The blackout must **remain active**, and Java must not get touch input.
4. Keep Treo active 90–120 s (no need to heat the device). Tap the new **round arrow button in the middle**. Confirm game view returns, touchscreen/joystick works, brightness restores, and auto/network/game state continue functioning.
5. Copy the full `[JarBoxVM][Treo]` line. It must include `thermal_start`, `thermal_end`, `thermal_peak`, `thermal_changes`. `main_CPU` should remain near the previous level, `springboard_loops_during_treo=0`; paint/GC/canvas fallback unchanged for a comparable scene. `thermal_peak=nominal` is a valid outcome; don't invent °C.

Accept if only the center button wakes from *touch*, screen touches don't reach the JAR, and CPU plus game state are stable. Reject if corners/swipes wake, center does not wake, or transitions leave brightness/AFK policy stuck. Source remains exclusively on the experimental branch; no change to `main`.

## Integrated, low-refresh Treo dashboard (next combined build)

The next combined experimental iPhone build includes a passive two-line HUD **below the 72×72-point center wake control**, without changing the wake target, original game JAR, JIT, GC, or Canvas policy.

- **CPU app (15s):** percent of *one logical core* from differences in `treo_process_cpu_seconds()` and `ProcessInfo.systemUptime` over the preceding ~15 s. The first display reads "đang đo" until a full interval has elapsed. This is **not instantaneous CPU**; a process may show more than 100% if multiple cores are active.
- **Pin:** `UIDevice.current.batteryLevel` in percentage. Battery monitoring is enabled only while Treo is active and its prior state is restored on exit and deinit. If unknown (<0) the display says "không rõ". Short sessions cannot estimate useful battery drain.
- **Nhiệt iOS:** system-wide `ProcessInfo.thermalState` (`nominal/fair/serious/critical`). This is not a temperature in °C and not a heat sensor API.
- One main-run-loop timer at **15 seconds**, tolerance **3 seconds**, no animation or CPU polling thread. The UILabel only changes if its text changes. `hud_updates=N` is appended to the standard Treo exit log so device measurements can attribute display work. The timer is invalidated immediately on exit and on controller deinit. This **does incur some wakeups and screen composites**, unlike the earlier static blackout. Do not claim zero power cost.

**No standalone build requested:** include this HUD, the centered wake button and thermal logging automatically in the next CPU-focused build. Keep the two preconfigured Codemagic workflows, with no user env changes or manual code edits.

### Test together with the next CPU experiment (not as a separate build)

1. Build the then-current `loader-ios-jit-probe` HEAD with Codemagic workflow **`J2ME Treo JIT probe unsigned`**. Install the newly generated IPA by the usual unsigned-IPA procedure.
2. Load the same JAR and scene, turn in-JAR Treo OFF, then enter **Treo tiết kiệm**. Verify only the central round icon exits Treo; tapping outside it and swiping do not.
3. Expect a 2-line CPU/battery/thermal label **below the center button**. The CPU value must change from "đang đo" after about 15–18 s; no transitions faster than once per ~15 s. The battery percentage can remain unchanged throughout. A `nominal` temperature category is normal and does not indicate degrees Celsius.
4. Hold the session 120–180 s, then touch the center icon. Confirm screen brightness, game input, auto/network and Smart GC all restore. Copy the `[JarBoxVM][Treo]` log including `hud_updates`, `app_CPU`, `main_CPU`, and `thermal_start/end/peak`. Both standard workflow builds contain the same HUD; compare only matched sessions and don't attribute CPU changes from older builds solely to other optimizations.
5. **Reject and fix** if the HUD refreshes rapidly, touches outside the center icon end Treo, battery monitoring stays enabled when it was previously disabled, brightness fails to restore, main CPU rises materially, or the view gets stuck. The animation fix and JAR semantics must not regress.

Source changes were structurally reviewed, but **Codemagic compilation, device visual visibility at brightness=0, and runtime CPU/battery impact are not yet confirmed**.
