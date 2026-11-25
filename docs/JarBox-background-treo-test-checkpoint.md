# Background Treo — 2D device-test candidate

Base a061063 CI SUCCESS; 2df09b1 scene GPU gate and a442b10 per-owner log precede this patch. This candidate requires a new successful iOS CI and device validation; no claim of continuous background operation. No JAR/JIT/logic-tick changes.

## Explicit audio opt-in

From game Debug or library JarBox menu choose **Âm nền Treo (thử nghiệm)**, then **Bật âm nền**. A single AVAudioPlayer plays a quiet, original four-second PCM loop, including in foreground; no silent volume, location permission, timer, per-VM player, or automatic startup. Stop via same menu. iOS may suspend/terminate regardless. Intended for personal device testing; background execution for game logic is not a guaranteed Apple API and audio-only keepalive may not satisfy App Review 2.5.4. The audio capability also enables actual known-2D game playback. Exclusive/unknown 3D uses SoloAmbient (silent switch respected) rather than Playback; 3D GL lifecycle is not certified.

All live eligible 2D tabs share the same physical audio session but not player handles or JVM state. A STARTING/exclusive owner prevents experimental playback; a stopping 2D peer alone does not stop an eligible surviving owner. Last running owner cleanup queues a revalidation, no raw VM pointer. Interruption resumes optional player only with shouldResume; route disconnect and media reset stop it until explicit restart. Java player ownership remains unchanged; media reset cannot rebuild existing Java players automatically. No session deactivation while game media may be active.

## Device tests after green CI
1. NSO original, 1 live game. Without audio, lock from game 60–120 s; unlock, copy Log Treo tắt màn hình.
2. Enable ambient; repeat from game. Confirm audible track and same session token.
3. Park two or more known-2D games in library; lock 2–5 min, unlock and copy report. Resume each game, verify connection/game progress. Close one game; other live game must retain audio. Close last game; optional player stops.
4. Interrupt via another app/call or disconnect headphones; inspect audio begin/end counters and gaps. No automatic restart after route loss/reset. Test no-game and STARTING rejection. Do not use 3D for long background tests.

Audio snapshots report requested/playing/interrupted and policy/reason, counters; reason 0 off, 1 playing, 2 ineligible, 3 interrupted, 4 route lost, 5 reset, 6 failure, 7 resume denied. They are boundary observations, not proof of continuous playback. NSO heartbeat is sampled from qualified repaint events on the Java thread; max gap includes first/last gaps. Lack of qualified heartbeat is inconclusive for games that do not emit it. Check in-game server-side progress too.

## Volume follow-up

Device baseline 5770c9d: the audible 35% player maintained qualified NSO heartbeat in the user's short tests, including two tabs. New volume choices 0/1/5/15/35/70/100 percent affect only the optional ambient player and persist across launches; playback still requires explicit opt-in. Default stays 35% until silent device validation. No automatic fallback or system-volume changes. The begin/end log includes selected and actual player volume plus cumulative volume change count; -1 means no player. For a matched comparison test 0% with one NSO tab locked for 2–5 minutes, then repeat at 35% if heartbeat stalls. Test library/two tabs at 0% if the first test succeeds. Do not infer supported or guaranteed silent background execution from isPlaying alone. App Review background-use restrictions remain applicable.

## Cross-device and power-state release gate

No special clock, CPU priority, networking, GC or tick policy for charging/unplugged/Low Power Mode. Boundary battery reads temporarily borrow and restore UIDevice monitoring; charging transitions between endpoints are not continuously recorded. Low Power Mode and thermal notifications are observed on the main queue, without a timer; missed notifications while suspended remain unknown. Report device machine identifier, OS, physical RAM, boundary battery percent/charge state, low power and thermal values, worst observed thermal and observed transition counts. Thermal codes 0 nominal, 1 fair, 2 serious, 3 critical, -1 unknown. Critical heat rejects optional playback or stops it on observed transition/revalidation (reason 8), does not stop JVMs or auto-restart audio. Reduce tab count if serious/critical; iOS may suspend. Empty library does not overwrite previous game report. Test silent mode at matched state first, then unplugged normal vs charging normal vs unplugged Low Power Mode, 2D one/two tabs, 15–30 min and 1h only if stable; record server progress and no unexpected route/interrupt events. Test real calls/media reset/headphone disconnect separately. Older supported devices are limited by actual iOS deployment target 18.0, existing memory admission and device measurements. No certification of all hardware or App Store silent keepalive.
