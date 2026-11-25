#ifndef J2ME_AUDIO_H
#define J2ME_AUDIO_H

#include "jvm.h"

#ifdef __cplusplus
extern "C" {
#endif

/// Register audio-related native methods with the JVM.
void j2me_audio_reg_natives(MiniJVM *jvm);

/// Stop and release only this JVM's audio handles. Required for
/// independently running games; never close another JVM's media players.
void j2me_audio_stop_for_vm(MiniJVM *vm);

// Explicit user-controlled ambient playback, separate from every JVM handle.
// These control/snapshot entry points are main-thread only.
typedef struct {
    int requested, playing, interrupted, policy, reason;
    uint64_t starts, stops, interruptions, route_changes, media_resets, failures;
} JarBoxBackgroundAudioSnapshot;
int j2me_audio_background_start(void);
void j2me_audio_background_stop(void);
void j2me_audio_background_revalidate(void);
JarBoxBackgroundAudioSnapshot j2me_audio_background_snapshot(void);

/// Global emergency cleanup only; not used by ordinary game shutdown.
void j2me_audio_stop_all(void);

#ifdef __cplusplus
}
#endif

#endif /* J2ME_AUDIO_H */
