"""Source contracts for native audio ownership during Multi-JVM preparation.

A real multi-JVM device test still requires independently scoped UI/render
and validation with simultaneous Java execution; this test never claims it.
"""
import re
import unittest
from pathlib import Path

BASE = Path(__file__).resolve().parents[2] / "J2MEEmulator/NativeBridge"
AUDIO = BASE / "j2me_audio.m"
BRIDGE = BASE / "jvm_bridge.c"
INPUT = BASE / "j2me_input.c"


class MultiVMAudioIsolationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.audio = AUDIO.read_text(encoding="utf-8")
        cls.bridge = BRIDGE.read_text(encoding="utf-8")
        cls.input = INPUT.read_text(encoding="utf-8")

    def test_completion_is_never_posted_to_arbitrary_foreground_jvm(self):
        self.assertIn('delegate.owner = owner;', self.audio)
        self.assertIn('delegate.generation = j2me_input_binding_generation(owner)', self.audio)
        self.assertIn('dispatch_async(dispatch_get_main_queue()', self.audio)
        self.assertIn('j2me_input_post_key_to_vm(owner, generation, J2ME_AUDIO_END_OF_MEDIA', self.audio)
        self.assertNotIn('j2me_input_post_key(J2ME_AUDIO_END_OF_MEDIA', self.audio)

    def test_player_handles_are_owned(self):
        self.assertIn('g_audio_owners', self.audio)
        self.assertIn('g_midi_owners', self.audio)
        self.assertIn('track_audio_player(player, runtime->jvm)', self.audio)
        self.assertIn('track_midi_player(player, runtime->jvm)', self.audio)
        for name, kind in [
            ('n_audioStart', 'NO'), ('n_audioStop', 'NO'),
            ('n_audioClose', 'NO'), ('n_audioSetLoop', 'NO'),
            ('n_audioSetVolume', 'NO'), ('n_audioGetDuration', 'NO'),
            ('n_audioGetTime', 'NO'),
            ('n_audioMidiStart', 'YES'), ('n_audioMidiStop', 'YES'),
            ('n_audioMidiClose', 'YES'),
        ]:
            with self.subTest(name=name):
                match = re.search(
                    r'static s32 ' + name + r'\([^)]*\)\s*\{(.*?)\n\}',
                    self.audio, re.DOTALL,
                )
                self.assertIsNotNone(match)
                self.assertIn(
                    'audio_owned_by_vm(runtime->jvm, (void *)(intptr_t)handle, ' + kind + ')',
                    match.group(1),
                )

    def test_stop_only_owning_session(self):
        self.assertIn('void j2me_audio_stop_for_vm(MiniJVM *vm)', self.audio)
        self.assertIn('if (vm == NULL || [owner pointerValue] == vm)', self.audio)
        self.assertIn('j2me_audio_stop_for_vm(slot->jvm)', self.bridge)
        self.assertNotIn('j2me_audio_stop_all();', self.bridge)
        self.assertIn('j2me_input_release_vm(slot->jvm)', self.bridge)
        # Still prohibit a second Java VM until renderer/MIDP UI are isolated.
        self.assertIn('bridge_reserve_slot_locked(', self.bridge)


if __name__ == "__main__":
    unittest.main()
