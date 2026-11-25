//
// j2me_audio.m — Audio bridge: AVAudioPlayer (WAV/MP3) + AVMIDIPlayer (MIDI)
//
// Maps J2ME media API to iOS AVFoundation.
// Analogous to J2ME-Loader's mapping to Android MediaPlayer + MidiDriver.
//

#import <AVFoundation/AVFoundation.h>
#include "j2me_audio.h"
#include "jvm_bridge.h"
#include "jarbox_ambient_pcm.h"
#include "j2me_input.h"
#include "jvm.h"
#include "jvm_util.h"
#include <stdio.h>

// ============================================================
// Audio session setup
// ============================================================

// AVAudioSession is shared by the process; optional playback is not a
// Java handle and never emits a Java audio completion event. All session
// activation/cache state is serialized with the existing audio lock.
enum { BG_AUDIO_OFF=0, BG_AUDIO_PLAYING=1, BG_AUDIO_INELIGIBLE=2,
       BG_AUDIO_INTERRUPTED=3, BG_AUDIO_ROUTE_LOST=4, BG_AUDIO_RESET=5,
       BG_AUDIO_FAILED=6, BG_AUDIO_RESUME_DENIED=7, BG_AUDIO_THERMAL_CRITICAL=8 };
static AVAudioPlayer *g_background_player;
static BOOL g_background_requested, g_audio_interrupted, g_audio_session_ready;
static int g_audio_session_category=-1, g_background_reason;
static uint64_t g_background_starts, g_background_stops, g_background_interruptions;
static uint64_t g_background_routes, g_background_resets, g_background_failures;
static uint64_t g_background_volume_changes;
static int g_background_volume_percent=35;
static BOOL g_background_volume_loaded;
static NSString * const kBackgroundVolumeKey=@"jarbox.background.audio.volume.percent.v1";

static int background_clamp_volume(int percent) {
    return percent<0?0:percent>100?100:percent;
}
// Caller holds the audio monitor. A stored zero is distinct from no setting.
static void background_load_volume_locked(void) {
    if (g_background_volume_loaded) return;
    NSUserDefaults *defaults=[NSUserDefaults standardUserDefaults];
    if ([defaults objectForKey:kBackgroundVolumeKey])
        g_background_volume_percent=background_clamp_volume((int)[defaults integerForKey:kBackgroundVolumeKey]);
    g_background_volume_loaded=YES;
}
void j2me_audio_background_set_volume(int percent) {
    if (![NSThread isMainThread]) return;
    @synchronized ([AVAudioSession class]) {
        background_load_volume_locked();
        percent=background_clamp_volume(percent);
        if (percent!=g_background_volume_percent) {
            g_background_volume_percent=percent;
            ++g_background_volume_changes;
            [[NSUserDefaults standardUserDefaults] setInteger:percent forKey:kBackgroundVolumeKey];
        }
        // This is solely the optional ambient player, not the system mixer
        // or the Java media players. No play/stop or session reactivation.
        g_background_player.volume=(float)percent/100.0f;
    }
}

static void background_stop_locked(int reason) {
    if (g_background_requested || g_background_player) ++g_background_stops;
    g_background_requested=NO;
    [g_background_player stop];
    g_background_player=nil;
    g_background_reason=reason;
    // Do not deactivate the process audio session out from under Java audio.
    // An active session without playing media is not a background grant.
}
static BOOL ensure_audio_locked(void) {
    if (g_audio_interrupted) return NO;
    // Exclusive/unknown 3D must not gain a background audio grant just
    // because the bundle now declares audio. Ambient respects screen lock
    // and the silent switch; known 2D retains playback and may mix.
    int category=jvm_bridge_background_audio_policy()!=0;
    AVAudioSession *session=[AVAudioSession sharedInstance];
    NSError *error=nil;
    if (g_audio_session_category!=category) {
        g_audio_session_ready=NO;
        NSString *name=category?AVAudioSessionCategoryPlayback:AVAudioSessionCategorySoloAmbient;
        AVAudioSessionCategoryOptions options=category?AVAudioSessionCategoryOptionMixWithOthers:0;
        if (![session setCategory:name mode:AVAudioSessionModeDefault options:options error:&error]) {
            NSLog(@"[JarBoxAudio] category failed: %@",error);
            g_audio_session_category=-1;
            return NO;
        }
        g_audio_session_category=category;
    }
    if (!g_audio_session_ready) {
        if (![session setActive:YES error:&error]) {
            NSLog(@"[JarBoxAudio] activation failed: %@",error);
            return NO;
        }
        g_audio_session_ready=YES;
    }
    return YES;
}
static BOOL background_play_locked(void) {
    if ([NSProcessInfo processInfo].thermalState==NSProcessInfoThermalStateCritical) {
        background_stop_locked(BG_AUDIO_THERMAL_CRITICAL);
        return NO;
    }
    if (jvm_bridge_background_audio_policy()!=2) {
        background_stop_locked(BG_AUDIO_INELIGIBLE);
        return NO;
    }
    if (g_audio_interrupted) {
        g_background_reason=BG_AUDIO_INTERRUPTED;
        return NO;
    }
    if (!ensure_audio_locked()) {
        ++g_background_failures;
        background_stop_locked(BG_AUDIO_FAILED);
        return NO;
    }
    if (!g_background_player) {
        NSMutableData *data=[NSMutableData dataWithLength:JARBOX_AMBIENT_BYTES];
        NSError *error=nil;
        if (jarbox_ambient_wav(data.mutableBytes,data.length))
            g_background_player=[[AVAudioPlayer alloc] initWithData:data error:&error];
        if (!g_background_player) {
            NSLog(@"[JarBoxAudio] ambient creation failed: %@",error);
            ++g_background_failures;
            background_stop_locked(BG_AUDIO_FAILED);
            return NO;
        }
        g_background_player.numberOfLoops=-1;
        background_load_volume_locked();
        // Retain the same source PCM and playback path at every volume.
        g_background_player.volume=(float)g_background_volume_percent/100.0f;
        if (![g_background_player prepareToPlay]) {
            ++g_background_failures;
            background_stop_locked(BG_AUDIO_FAILED);
            return NO;
        }
    }
    if (!g_background_player.isPlaying) {
        if (![g_background_player play]) {
            ++g_background_failures;
            background_stop_locked(BG_AUDIO_FAILED);
            return NO;
        }
        ++g_background_starts;
    }
    g_background_reason=BG_AUDIO_PLAYING;
    return YES;
}
static void install_audio_observers(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSNotificationCenter *center=[NSNotificationCenter defaultCenter];
        [center addObserverForName:AVAudioSessionInterruptionNotification object:nil
                           queue:nil usingBlock:^(NSNotification *note) {
            dispatch_async(dispatch_get_main_queue(), ^{
            @synchronized ([AVAudioSession class]) {
                NSNumber *type=note.userInfo[AVAudioSessionInterruptionTypeKey];
                if (type.unsignedIntegerValue==AVAudioSessionInterruptionTypeBegan) {
                    g_audio_interrupted=YES;
                    g_audio_session_ready=NO;
                    ++g_background_interruptions;
                    if (g_background_requested) {
                        [g_background_player pause];
                        g_background_reason=BG_AUDIO_INTERRUPTED;
                    }
                } else if (type.unsignedIntegerValue==AVAudioSessionInterruptionTypeEnded) {
                    g_audio_interrupted=NO;
                    g_audio_session_ready=NO;
                    NSNumber *options=note.userInfo[AVAudioSessionInterruptionOptionKey];
                    if (g_background_requested) {
                        if (options.unsignedIntegerValue & AVAudioSessionInterruptionOptionShouldResume)
                            (void)background_play_locked();
                        else background_stop_locked(BG_AUDIO_RESUME_DENIED);
                    }
                }
            }
            });
        }];
        [center addObserverForName:AVAudioSessionRouteChangeNotification object:nil
                           queue:nil usingBlock:^(NSNotification *note) {
            dispatch_async(dispatch_get_main_queue(), ^{
            @synchronized ([AVAudioSession class]) {
                ++g_background_routes;
                NSNumber *reason=note.userInfo[AVAudioSessionRouteChangeReasonKey];
                // Do not surprise the user by restarting on speakers after unplug.
                if (g_background_requested &&
                    reason.unsignedIntegerValue==AVAudioSessionRouteChangeReasonOldDeviceUnavailable)
                    background_stop_locked(BG_AUDIO_ROUTE_LOST);
            }
            });
        }];
        [center addObserverForName:AVAudioSessionMediaServicesWereResetNotification object:nil
                           queue:nil usingBlock:^(NSNotification *note) {
            dispatch_async(dispatch_get_main_queue(), ^{
            (void)note;
            @synchronized ([AVAudioSession class]) {
                ++g_background_resets;
                g_audio_session_ready=NO;
                g_audio_session_category=-1;
                g_audio_interrupted=NO;
                // Media services invalidated the old player. User re-arms
                // playback explicitly; do not silently restart Java players.
                if (g_background_requested || g_background_player)
                    background_stop_locked(BG_AUDIO_RESET);
            }
            });
        }];
    });
}
static BOOL ensureAudioSession(void) {
    install_audio_observers();
    @synchronized ([AVAudioSession class]) { return ensure_audio_locked(); }
}
int j2me_audio_background_start(void) {
    if (![NSThread isMainThread]) return 0;
    install_audio_observers();
    @synchronized ([AVAudioSession class]) {
        if (g_audio_interrupted) {
            g_background_reason=BG_AUDIO_INTERRUPTED;
            return 0;
        }
        g_background_requested=YES;
        return background_play_locked();
    }
}
void j2me_audio_background_stop(void) {
    if (![NSThread isMainThread]) return;
    @synchronized ([AVAudioSession class]) { background_stop_locked(BG_AUDIO_OFF); }
}
void j2me_audio_background_revalidate(void) {
    if (![NSThread isMainThread]) return;
    @synchronized ([AVAudioSession class]) {
        if ((g_background_requested || g_background_player) &&
            [NSProcessInfo processInfo].thermalState==NSProcessInfoThermalStateCritical)
            background_stop_locked(BG_AUDIO_THERMAL_CRITICAL);
        else if ((g_background_requested || g_background_player) &&
            jvm_bridge_background_audio_policy()!=2)
            background_stop_locked(BG_AUDIO_INELIGIBLE);
        else if (g_background_requested && !g_audio_interrupted && !g_background_player.isPlaying) {
            ++g_background_failures;
            background_stop_locked(BG_AUDIO_FAILED);
        }
    }
}
JarBoxBackgroundAudioSnapshot j2me_audio_background_snapshot(void) {
    JarBoxBackgroundAudioSnapshot out={0};
    @synchronized ([AVAudioSession class]) {
        out.requested=g_background_requested; out.playing=g_background_player.isPlaying;
        out.interrupted=g_audio_interrupted; out.policy=jvm_bridge_background_audio_policy();
        background_load_volume_locked();
        out.volume_percent=g_background_volume_percent;
        out.player_volume_percent=g_background_player?(int)lroundf(g_background_player.volume*100.0f):-1;
        out.volume_changes=g_background_volume_changes;
        out.reason=g_background_reason; out.starts=g_background_starts; out.stops=g_background_stops;
        out.interruptions=g_background_interruptions; out.route_changes=g_background_routes;
        out.media_resets=g_background_resets; out.failures=g_background_failures;
    }
    return out;
}

// ============================================================
// SoundFont path for MIDI
// ============================================================

static NSURL *getSoundFontURL(void) {
    static NSURL *url = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        // Try various subdirectory locations
        url = [[NSBundle mainBundle] URLForResource:@"gs_instruments" withExtension:@"sf2"];
        if (!url) {
            url = [[NSBundle mainBundle] URLForResource:@"gs_instruments" withExtension:@"sf2"
                                           subdirectory:@"sound_fonts"];
        }
        if (!url) {
            url = [[NSBundle mainBundle] URLForResource:@"gs_instruments" withExtension:@"sf2"
                                           subdirectory:@"Resources/sound_fonts"];
        }
        if (!url) {
            // Brute-force search
            NSString *path = [[NSBundle mainBundle] pathForResource:@"gs_instruments" ofType:@"sf2"];
            if (path) url = [NSURL fileURLWithPath:path];
        }
        if (!url) {
            printf("[J2ME Audio] WARNING: gs_instruments.sf2 not found in bundle!\n");
        }
    });
    return url;
}

// ============================================================
// Completion events and per-JVM audio ownership
// ============================================================

#define J2ME_AUDIO_END_OF_MEDIA 13

// A physical AVAudioSession is an iOS shared resource; individual player
// ownership, callbacks and teardown are nevertheless scoped to their JVM.
@interface J2MEAudioDelegate : NSObject <AVAudioPlayerDelegate>
@property(nonatomic, assign) MiniJVM *owner;
@property(nonatomic, assign) uint64_t generation;
@end

@implementation J2MEAudioDelegate
- (void)audioPlayerDidFinishPlaying:(AVAudioPlayer *)player successfully:(BOOL)flag {
    MiniJVM *owner = self.owner;
    uint64_t generation = self.generation;
    // The Java input ring is SPSC: route completion onto the same iOS main
    // producer queue as physical input, and require the old binding generation.
    dispatch_async(dispatch_get_main_queue(), ^{
        j2me_input_post_key_to_vm(owner, generation, J2ME_AUDIO_END_OF_MEDIA, 0);
    });
}
@end

static NSMutableSet<AVAudioPlayer *> *g_active_audio_players;
static NSMutableSet<AVMIDIPlayer *> *g_active_midi_players;
static NSMutableDictionary<NSValue *, NSValue *> *g_audio_owners;
static NSMutableDictionary<NSValue *, NSValue *> *g_midi_owners;
static NSMutableDictionary<NSValue *, J2MEAudioDelegate *> *g_player_delegates;

static NSValue *audio_key(const void *pointer) {
    return [NSValue valueWithPointer:pointer];
}

static BOOL audio_owned_by_vm(MiniJVM *vm, const void *player, BOOL midi) {
    if (!vm || !player) return NO;
    @synchronized ([AVAudioSession class]) {
        NSValue *key = audio_key(player);
        NSValue *owner = midi ? g_midi_owners[key] : g_audio_owners[key];
        return owner != nil && [owner pointerValue] == vm;
    }
}

static void track_audio_player(AVAudioPlayer *player, MiniJVM *owner) {
    @synchronized ([AVAudioSession class]) {
        if (!g_active_audio_players) g_active_audio_players = [NSMutableSet new];
        if (!g_audio_owners) g_audio_owners = [NSMutableDictionary new];
        if (!g_player_delegates) g_player_delegates = [NSMutableDictionary new];
        J2MEAudioDelegate *delegate = [[J2MEAudioDelegate alloc] init];
        delegate.owner = owner;
        delegate.generation = j2me_input_binding_generation(owner);
        player.delegate = delegate;
        NSValue *key = audio_key((__bridge const void *)player);
        [g_active_audio_players addObject:player];
        g_audio_owners[key] = audio_key(owner);
        g_player_delegates[key] = delegate;
    }
}

// Exactly one close/teardown path wins ownership of the CF-retained handle.
static BOOL untrack_audio_player(AVAudioPlayer *player, MiniJVM *owner) {
    @synchronized ([AVAudioSession class]) {
        if (!audio_owned_by_vm(owner, (__bridge const void *)player, NO)) return NO;
        NSValue *key = audio_key((__bridge const void *)player);
        player.delegate = nil;
        [g_active_audio_players removeObject:player];
        [g_audio_owners removeObjectForKey:key];
        [g_player_delegates removeObjectForKey:key];
        return YES;
    }
}

static void track_midi_player(AVMIDIPlayer *player, MiniJVM *owner) {
    @synchronized ([AVAudioSession class]) {
        if (!g_active_midi_players) g_active_midi_players = [NSMutableSet new];
        if (!g_midi_owners) g_midi_owners = [NSMutableDictionary new];
        [g_active_midi_players addObject:player];
        g_midi_owners[audio_key((__bridge const void *)player)] = audio_key(owner);
    }
}

static BOOL untrack_midi_player(AVMIDIPlayer *player, MiniJVM *owner) {
    @synchronized ([AVAudioSession class]) {
        if (!audio_owned_by_vm(owner, (__bridge const void *)player, YES)) return NO;
        [g_active_midi_players removeObject:player];
        [g_midi_owners removeObjectForKey:audio_key((__bridge const void *)player)];
        return YES;
    }
}

static void stop_owned_audio_players(MiniJVM *vm) {
    NSMutableArray<AVAudioPlayer *> *audio = [NSMutableArray new];
    NSMutableArray<AVMIDIPlayer *> *midi = [NSMutableArray new];
    @synchronized ([AVAudioSession class]) {
        for (AVAudioPlayer *p in [g_active_audio_players copy]) {
            NSValue *key = audio_key((__bridge const void *)p);
            NSValue *owner = g_audio_owners[key];
            if (vm == NULL || [owner pointerValue] == vm) {
                p.delegate = nil;
                [audio addObject:p];
                [g_active_audio_players removeObject:p];
                [g_audio_owners removeObjectForKey:key];
                [g_player_delegates removeObjectForKey:key];
            }
        }
        for (AVMIDIPlayer *p in [g_active_midi_players copy]) {
            NSValue *key = audio_key((__bridge const void *)p);
            NSValue *owner = g_midi_owners[key];
            if (vm == NULL || [owner pointerValue] == vm) {
                [midi addObject:p];
                [g_active_midi_players removeObject:p];
                [g_midi_owners removeObjectForKey:key];
            }
        }
    }
    for (AVAudioPlayer *p in audio) {
        [p stop];
        CFRelease((__bridge CFTypeRef)p);
    }
    if (midi.count) {
        // AVMIDIPlayer's AUGraph must be stopped/deallocated on main.
        void (^releaseMIDI)(void) = ^{
            for (AVMIDIPlayer *p in midi) {
                [p stop];
                CFRelease((__bridge CFTypeRef)p);
            }
        };
        if ([NSThread isMainThread]) releaseMIDI();
        else dispatch_sync(dispatch_get_main_queue(), releaseMIDI);
    }
    printf("[J2ME Audio] Stopped owned players (wav=%lu midi=%lu)\n",
           (unsigned long)audio.count, (unsigned long)midi.count);
}

void j2me_audio_stop_for_vm(MiniJVM *vm) {
    if (vm) {
        stop_owned_audio_players(vm);
        // No raw owner escapes. Cleanup already published CLEANUP; recheck
        // current slots on main, preserving ambient if another 2D is running.
        dispatch_async(dispatch_get_main_queue(), ^{ j2me_audio_background_revalidate(); });
    }
}

void j2me_audio_stop_all(void) {
    // Explicit global emergency teardown only; ordinary JVM cleanup must
    // call j2me_audio_stop_for_vm, never touch other games' sound.
    stop_owned_audio_players(NULL);
    dispatch_async(dispatch_get_main_queue(), ^{ j2me_audio_background_stop(); });
}

// ============================================================
// WAV/MP3 — AVAudioPlayer
// ============================================================

static s32 n_audioCreatePlayer(Runtime *runtime, JClass *clazz) {
    JniEnv *env = runtime->jnienv;
    Instance *arr = env->localvar_getRefer(runtime->localvar, 0);

    if (!arr) { env->push_long(runtime->stack, 0); return RUNTIME_STATUS_NORMAL; }

    ensureAudioSession();

    s32 length = arr->arr_length;
    NSData *data = [NSData dataWithBytes:arr->arr_body length:length];

    NSError *error = nil;
    AVAudioPlayer *player = [[AVAudioPlayer alloc] initWithData:data error:&error];
    if (error || !player) {
        printf("[J2ME Audio] AVAudioPlayer init error: %s\n",
               error ? [[error localizedDescription] UTF8String] : "nil");
        env->push_long(runtime->stack, 0);
        return RUNTIME_STATUS_NORMAL;
    }

    [player prepareToPlay];
    // Prevent ARC from releasing — bridge retain
    CFRetain((__bridge CFTypeRef)player);
    track_audio_player(player, runtime->jvm);
    env->push_long(runtime->stack, (s64)(intptr_t)(__bridge void *)player);
    return RUNTIME_STATUS_NORMAL;
}

static s32 n_audioStart(Runtime *runtime, JClass *clazz) {
    JniEnv *env = runtime->jnienv;
    s64 handle = env->localvar_getLong_2slot(runtime->localvar, 0);
    if (handle && audio_owned_by_vm(runtime->jvm, (void *)(intptr_t)handle, NO)) {
        AVAudioPlayer *player = (__bridge AVAudioPlayer *)(void *)(intptr_t)handle;
        if (ensureAudioSession()) [player play];
    }
    return RUNTIME_STATUS_NORMAL;
}

static s32 n_audioStop(Runtime *runtime, JClass *clazz) {
    JniEnv *env = runtime->jnienv;
    s64 handle = env->localvar_getLong_2slot(runtime->localvar, 0);
    if (handle && audio_owned_by_vm(runtime->jvm, (void *)(intptr_t)handle, NO)) {
        AVAudioPlayer *player = (__bridge AVAudioPlayer *)(void *)(intptr_t)handle;
        [player pause];
    }
    return RUNTIME_STATUS_NORMAL;
}

static s32 n_audioClose(Runtime *runtime, JClass *clazz) {
    JniEnv *env = runtime->jnienv;
    s64 handle = env->localvar_getLong_2slot(runtime->localvar, 0);
    if (handle && audio_owned_by_vm(runtime->jvm, (void *)(intptr_t)handle, NO)) {
        AVAudioPlayer *player = (__bridge AVAudioPlayer *)(void *)(intptr_t)handle;
        if (untrack_audio_player(player, runtime->jvm)) {
            [player stop];
            CFRelease((__bridge CFTypeRef)player);
        }
    }
    return RUNTIME_STATUS_NORMAL;
}

static s32 n_audioSetLoop(Runtime *runtime, JClass *clazz) {
    JniEnv *env = runtime->jnienv;
    s64 handle = env->localvar_getLong_2slot(runtime->localvar, 0);
    s32 count = env->localvar_getInt(runtime->localvar, 2);
    if (handle && audio_owned_by_vm(runtime->jvm, (void *)(intptr_t)handle, NO)) {
        AVAudioPlayer *player = (__bridge AVAudioPlayer *)(void *)(intptr_t)handle;
        player.numberOfLoops = count; // -1 = infinite, 0 = play once
    }
    return RUNTIME_STATUS_NORMAL;
}

static s32 n_audioSetVolume(Runtime *runtime, JClass *clazz) {
    JniEnv *env = runtime->jnienv;
    s64 handle = env->localvar_getLong_2slot(runtime->localvar, 0);
    // float is passed as int bits in localvar slot 2
    s32 bits = env->localvar_getInt(runtime->localvar, 2);
    float volume;
    memcpy(&volume, &bits, sizeof(float));
    if (handle && audio_owned_by_vm(runtime->jvm, (void *)(intptr_t)handle, NO)) {
        AVAudioPlayer *player = (__bridge AVAudioPlayer *)(void *)(intptr_t)handle;
        player.volume = volume;
    }
    return RUNTIME_STATUS_NORMAL;
}

static s32 n_audioGetDuration(Runtime *runtime, JClass *clazz) {
    JniEnv *env = runtime->jnienv;
    s64 handle = env->localvar_getLong_2slot(runtime->localvar, 0);
    s64 duration = -1;
    if (handle && audio_owned_by_vm(runtime->jvm, (void *)(intptr_t)handle, NO)) {
        AVAudioPlayer *player = (__bridge AVAudioPlayer *)(void *)(intptr_t)handle;
        duration = (s64)(player.duration * 1000000.0); // microseconds
    }
    env->push_long(runtime->stack, duration);
    return RUNTIME_STATUS_NORMAL;
}

static s32 n_audioGetTime(Runtime *runtime, JClass *clazz) {
    JniEnv *env = runtime->jnienv;
    s64 handle = env->localvar_getLong_2slot(runtime->localvar, 0);
    s64 time = 0;
    if (handle && audio_owned_by_vm(runtime->jvm, (void *)(intptr_t)handle, NO)) {
        AVAudioPlayer *player = (__bridge AVAudioPlayer *)(void *)(intptr_t)handle;
        time = (s64)(player.currentTime * 1000000.0); // microseconds
    }
    env->push_long(runtime->stack, time);
    return RUNTIME_STATUS_NORMAL;
}

// ============================================================
// MIDI — AVMIDIPlayer + gs_instruments.sf2
// ============================================================

static s32 n_audioCreateMidiPlayer(Runtime *runtime, JClass *clazz) {
    JniEnv *env = runtime->jnienv;
    Instance *arr = env->localvar_getRefer(runtime->localvar, 0);

    if (!arr) { env->push_long(runtime->stack, 0); return RUNTIME_STATUS_NORMAL; }

    ensureAudioSession();

    s32 length = arr->arr_length;
    NSData *data = [NSData dataWithBytes:arr->arr_body length:length];
    NSURL *sfURL = getSoundFontURL();

    NSError *error = nil;
    AVMIDIPlayer *player = [[AVMIDIPlayer alloc] initWithData:data
                                                 soundBankURL:sfURL
                                                        error:&error];
    if (error || !player) {
        printf("[J2ME Audio] AVMIDIPlayer init error: %s\n",
               error ? [[error localizedDescription] UTF8String] : "nil");
        env->push_long(runtime->stack, 0);
        return RUNTIME_STATUS_NORMAL;
    }

    [player prepareToPlay];
    CFRetain((__bridge CFTypeRef)player);
    track_midi_player(player, runtime->jvm);
    env->push_long(runtime->stack, (s64)(intptr_t)(__bridge void *)player);
    return RUNTIME_STATUS_NORMAL;
}

static s32 n_audioMidiStart(Runtime *runtime, JClass *clazz) {
    JniEnv *env = runtime->jnienv;
    s64 handle = env->localvar_getLong_2slot(runtime->localvar, 0);
    if (handle && audio_owned_by_vm(runtime->jvm, (void *)(intptr_t)handle, YES)) {
        AVMIDIPlayer *player = (__bridge AVMIDIPlayer *)(void *)(intptr_t)handle;
        if (ensureAudioSession()) [player play:nil];
    }
    return RUNTIME_STATUS_NORMAL;
}

static s32 n_audioMidiStop(Runtime *runtime, JClass *clazz) {
    JniEnv *env = runtime->jnienv;
    s64 handle = env->localvar_getLong_2slot(runtime->localvar, 0);
    if (handle && audio_owned_by_vm(runtime->jvm, (void *)(intptr_t)handle, YES)) {
        AVMIDIPlayer *player = (__bridge AVMIDIPlayer *)(void *)(intptr_t)handle;
        [player stop];
    }
    return RUNTIME_STATUS_NORMAL;
}

static s32 n_audioMidiClose(Runtime *runtime, JClass *clazz) {
    JniEnv *env = runtime->jnienv;
    s64 handle = env->localvar_getLong_2slot(runtime->localvar, 0);
    if (handle && audio_owned_by_vm(runtime->jvm, (void *)(intptr_t)handle, YES)) {
        AVMIDIPlayer *player = (__bridge AVMIDIPlayer *)(void *)(intptr_t)handle;
        if (untrack_midi_player(player, runtime->jvm)) {
            [player stop];
            CFRelease((__bridge CFTypeRef)player);
        }
    }
    return RUNTIME_STATUS_NORMAL;
}

// ============================================================
// Tone — convenience (not used directly, Java uses ToneManager)
// ============================================================

static s32 n_audioPlayTone(Runtime *runtime, JClass *clazz) {
    // This is a fallback — normally ToneManager handles playTone via TonePlayer
    JniEnv *env = runtime->jnienv;
    s32 note = env->localvar_getInt(runtime->localvar, 0);
    s32 duration = env->localvar_getInt(runtime->localvar, 1);
    s32 volume = env->localvar_getInt(runtime->localvar, 2);
    printf("[J2ME Audio] playTone: note=%d duration=%d volume=%d\n", note, duration, volume);
    // Tone is handled by Java ToneManager → ToneSequence → MIDI → AVMIDIPlayer
    return RUNTIME_STATUS_NORMAL;
}

// ============================================================
// Native method table
// ============================================================

#define CLS "javax/microedition/lcdui/NativeBridge"

static java_native_method j2me_audio_methods[] = {
    // WAV/MP3
    {CLS, "audioCreatePlayer",     "([B)J",   n_audioCreatePlayer},
    {CLS, "audioStart",            "(J)V",    n_audioStart},
    {CLS, "audioStop",             "(J)V",    n_audioStop},
    {CLS, "audioClose",            "(J)V",    n_audioClose},
    {CLS, "audioSetLoop",          "(JI)V",   n_audioSetLoop},
    {CLS, "audioSetVolume",        "(JF)V",   n_audioSetVolume},
    {CLS, "audioGetDuration",      "(J)J",    n_audioGetDuration},
    {CLS, "audioGetTime",          "(J)J",    n_audioGetTime},
    // MIDI
    {CLS, "audioCreateMidiPlayer", "([B)J",   n_audioCreateMidiPlayer},
    {CLS, "audioMidiStart",        "(J)V",    n_audioMidiStart},
    {CLS, "audioMidiStop",         "(J)V",    n_audioMidiStop},
    {CLS, "audioMidiClose",        "(J)V",    n_audioMidiClose},
    // Tone
    {CLS, "audioPlayTone",         "(III)V",  n_audioPlayTone},
};

#undef CLS

void j2me_audio_reg_natives(MiniJVM *jvm) {
    native_reg_lib(jvm, j2me_audio_methods,
                   sizeof(j2me_audio_methods) / sizeof(java_native_method));
    printf("[J2ME Audio] Registered %lu native methods\n",
           sizeof(j2me_audio_methods) / sizeof(java_native_method));
}
