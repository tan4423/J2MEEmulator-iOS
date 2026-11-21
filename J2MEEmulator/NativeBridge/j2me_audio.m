//
// j2me_audio.m — Audio bridge: AVAudioPlayer (WAV/MP3) + AVMIDIPlayer (MIDI)
//
// Maps J2ME media API to iOS AVFoundation.
// Analogous to J2ME-Loader's mapping to Android MediaPlayer + MidiDriver.
//

#import <AVFoundation/AVFoundation.h>
#include "j2me_audio.h"
#include "j2me_input.h"
#include "jvm.h"
#include "jvm_util.h"
#include <stdio.h>

// ============================================================
// Audio session setup
// ============================================================

static void ensureAudioSession(void) {
    static BOOL initialized = NO;
    if (!initialized) {
        NSError *error = nil;
        [[AVAudioSession sharedInstance] setCategory:AVAudioSessionCategoryPlayback error:&error];
        [[AVAudioSession sharedInstance] setActive:YES error:&error];
        if (error) {
            printf("[J2ME Audio] Audio session error: %s\n",
                   [[error localizedDescription] UTF8String]);
        }
        initialized = YES;
    }
}

// ============================================================
// SoundFont path for MIDI
// ============================================================

static NSURL *getSoundFontURL(void) {
    static NSURL *url = nil;
    if (!url) {
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
    }
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
    if (vm) stop_owned_audio_players(vm);
}

void j2me_audio_stop_all(void) {
    // Explicit global emergency teardown only; ordinary JVM cleanup must
    // call j2me_audio_stop_for_vm, never touch other games' sound.
    stop_owned_audio_players(NULL);
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
        [player play];
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
        [player play:nil];
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
