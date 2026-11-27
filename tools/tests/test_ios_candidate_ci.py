import tempfile
import unittest
import plistlib
from pathlib import Path
from zipfile import ZipFile
import sys
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from run_ios_candidate_ci import BINARY, RESIDUAL, CANDIDATES, OFF, prepare, verify_ipa


def config():
    return {'workflows': {'jit-probe-unsigned': {
        'environment': {'vars': dict.fromkeys(CANDIDATES + (BINARY, RESIDUAL) + OFF, '0')},
        'scripts': [{'name': 'Build and package unsigned iPhone IPA', 'script': 'set -euo pipefail\ntrue'}]
    }}}


class IOSCandidateTest(unittest.TestCase):
    def test_isolation(self):
        c = config()
        _, e = prepare(c, 'intrinsics', {'PATH': '/bin', 'JARBOX_OTHER': '1', OFF[0]: '1'})
        self.assertEqual(e['PATH'], '/bin')
        self.assertNotIn('JARBOX_OTHER', e)
        self.assertTrue(all(e[k] == '0' for k in OFF))
        self.assertTrue(all(e[k] == '1' for k in CANDIDATES))
        self.assertEqual(e[BINARY], '0')
        self.assertEqual(e[RESIDUAL], '0')
        candidate=prepare(c, 'residual', {})[1]
        self.assertEqual(candidate[RESIDUAL], '1')
        self.assertEqual(candidate['JARBOX_NINJA_CORE_EXPERIMENT'], '1')
        self.assertEqual(candidate[BINARY], '0')
        self.assertTrue(all(candidate[k]=='0' for k in CANDIDATES+tuple(x for x in OFF if x!='JARBOX_NINJA_CORE_EXPERIMENT')))
        binary=prepare(c, 'binary', {})[1]
        self.assertEqual(binary[BINARY], '1')
        trial=prepare(c, 'binary-trial', {})[1]
        self.assertEqual(trial[BINARY], '2')
        self.assertTrue(all(trial[k]=='0' for k in CANDIDATES+OFF))
        self.assertTrue(all(trial[k]=='0' for k in ('JARBOX_NATIVE_PAINT_DIAG','JARBOX_REGION_STAGE_DIAG','JARBOX_HOTSPOT_DIAG')))
        self.assertTrue(all(binary[k]=='0' for k in CANDIDATES+OFF))
        self.assertTrue(all(prepare(c, 'control', {})[1][k] == '0' for k in CANDIDATES + OFF))
        self.assertEqual(c['workflows']['jit-probe-unsigned']['environment']['vars'][CANDIDATES[0]], '0')

    def test_changed_default(self):
        c = config()
        c['workflows']['jit-probe-unsigned']['environment']['vars'][OFF[0]] = '1'
        with self.assertRaises(ValueError):
            prepare(c, 'intrinsics', {})

    def test_archive(self):
        profile = 'const-arith-0_const-branch-0_decoded-int-0_event-sleep-0_paint-qos-0_ninja-core-0_core-aba-0_array-mode1-1_char-leaf-1_binary-sprite-0_residual-0'
        with tempfile.TemporaryDirectory() as d:
            p = Path(d) / 'test.ipa'
            for actual, sha, extra in [(profile, 'a', False), (profile.replace('core-aba-0','core-aba-1'), 'a', False), (profile, 'b', False), (profile, 'a', True), (profile+'_char-leaf-0','a',False)]:
                with ZipFile(p, 'w') as z:
                    z.writestr('Payload/JarBox.app/Info.plist', plistlib.dumps({'JarBoxPerfProfile': actual, 'JarBoxBuildCommit': sha}))
                    if extra:
                        z.writestr('Payload/Other.app/Info.plist', b'')
                if actual == profile and sha == 'a' and not extra:
                    self.assertEqual(verify_ipa(p, 'a', 'intrinsics'), profile)
                    with self.assertRaises(ValueError):
                        verify_ipa(p, 'a', 'control')
                else:
                    with self.assertRaises(ValueError):
                        verify_ipa(p, 'a', 'intrinsics')


if __name__ == '__main__':
    unittest.main()
