import tempfile
import unittest
import plistlib
from pathlib import Path
from zipfile import ZipFile
import sys
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from run_ios_candidate_ci import BINARY, RESIDUAL, BLOCK_IR, RENDER_ISLAND, GC_INDEX, RECONSTRUCT, CANDIDATES, OFF, prepare, verify_ipa
from generate_residual_build_identity import generate
import hashlib


def config():
    return {'workflows': {'jit-probe-unsigned': {
        'environment': {'vars': dict.fromkeys(CANDIDATES + (BINARY, RESIDUAL, BLOCK_IR, RENDER_ISLAND, GC_INDEX, RECONSTRUCT) + OFF, '0')},
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
        self.assertEqual(candidate[BLOCK_IR], '0')
        headless=prepare(c, 'headless', {BLOCK_IR:'0'})[1]
        self.assertEqual(headless[RESIDUAL], '1')
        self.assertEqual(headless[BLOCK_IR], '1')
        self.assertEqual(headless[RENDER_ISLAND], '0')
        render=prepare(c, 'headless-render', {})[1]
        self.assertEqual(render[RENDER_ISLAND], '1')
        self.assertEqual(render[BLOCK_IR], '1')
        self.assertEqual(render[RESIDUAL], '1')
        self.assertEqual(render['JARBOX_NINJA_CORE_EXPERIMENT'], '1')
        self.assertEqual(render[BINARY], '0')
        self.assertEqual(render[GC_INDEX], '0')
        combined=prepare(c, 'headless-render-gc', {GC_INDEX:'0'})[1]
        self.assertEqual(combined[GC_INDEX], '1')
        self.assertEqual(combined[RECONSTRUCT], '0')
        rebuilt=prepare(c,'headless-reconstructed',{})[1]
        self.assertEqual(rebuilt[RECONSTRUCT],'1')
        self.assertEqual({k:v for k,v in rebuilt.items() if k!=RECONSTRUCT},
                         {k:v for k,v in combined.items() if k!=RECONSTRUCT})
        for config_name in ('control','intrinsics','binary','binary-trial','residual','headless','headless-render','headless-render-gc'):
            self.assertEqual(prepare(c,config_name,{RECONSTRUCT:'1'})[1][RECONSTRUCT],'0')
        self.assertEqual({k:v for k,v in combined.items() if k!=GC_INDEX},
                         {k:v for k,v in render.items() if k!=GC_INDEX})
        for config_name in ('control','intrinsics','binary','binary-trial','residual','headless','headless-render'):
            self.assertEqual(prepare(c,config_name,{GC_INDEX:'1'})[1][GC_INDEX],'0')
        for config_name in ('control','intrinsics','binary','binary-trial','residual','headless'):
            self.assertEqual(prepare(c,config_name,{RENDER_ISLAND:'1'})[1][RENDER_ISLAND],'0')
        self.assertEqual(headless['JARBOX_NINJA_CORE_EXPERIMENT'], '1')
        self.assertEqual(headless[BINARY], '0')
        self.assertTrue(all(headless[k]=='0' for k in CANDIDATES+tuple(x for x in OFF if x!='JARBOX_NINJA_CORE_EXPERIMENT')))
        for config_name in ('control','intrinsics','binary','binary-trial','residual'):
            self.assertEqual(prepare(c,config_name,{BLOCK_IR:'1'})[1][BLOCK_IR],'0')
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

    def test_residual_build_identity(self):
        with tempfile.TemporaryDirectory() as d:
            root=Path(d);out=root/'identity.h'
            for name,body in [('j2me_api.jar',b'api'),('minijvm_rt.jar',b'boot')]:
                (root/name).write_bytes(body)
            generate(root,out);first=out.read_text()
            generate(root,out);self.assertEqual(first,out.read_text())
            for body in (b'api',b'boot'):
                self.assertIn(','.join('0x%02x'%x for x in hashlib.sha256(body).digest()),first)
            (root/'j2me_api.jar').write_bytes(b'')
            with self.assertRaises(ValueError):generate(root,out)

    def test_headless_packaged_identity(self):
        profile='const-arith-0_const-branch-0_decoded-int-0_event-sleep-0_paint-qos-0_ninja-core-1_core-aba-0_array-mode1-0_char-leaf-0_binary-sprite-0_residual-1_block-ir-1_render-island-0_gc-index-0_reconstruct-0'
        with tempfile.TemporaryDirectory() as d:
            p=Path(d)/'test.ipa'
            with ZipFile(p,'w') as z:
                z.writestr('Payload/JarBox.app/Info.plist',plistlib.dumps({'JarBoxPerfProfile':profile,'JarBoxBuildCommit':'a'}))
            self.assertEqual(verify_ipa(p,'a','headless'),profile)
            with self.assertRaises(ValueError):
                verify_ipa(p,'a','residual')
            with self.assertRaises(ValueError):
                verify_ipa(p,'a','headless-render')
            render_profile=profile.replace('render-island-0','render-island-1')
            with ZipFile(p,'w') as z:
                z.writestr('Payload/JarBox.app/Info.plist',plistlib.dumps({'JarBoxPerfProfile':render_profile,'JarBoxBuildCommit':'a'}))
            self.assertEqual(verify_ipa(p,'a','headless-render'),render_profile)
            with self.assertRaises(ValueError):
                verify_ipa(p,'a','headless-render-gc')
            gc_profile=render_profile.replace('gc-index-0','gc-index-1')
            with ZipFile(p,'w') as z:
                z.writestr('Payload/JarBox.app/Info.plist',plistlib.dumps({'JarBoxPerfProfile':gc_profile,'JarBoxBuildCommit':'a'}))
            self.assertEqual(verify_ipa(p,'a','headless-render-gc'),gc_profile)
            with self.assertRaises(ValueError):
                verify_ipa(p,'a','headless-reconstructed')
            rebuilt_profile=gc_profile.replace('reconstruct-0','reconstruct-1')
            with ZipFile(p,'w') as z:
                z.writestr('Payload/JarBox.app/Info.plist',plistlib.dumps({'JarBoxPerfProfile':rebuilt_profile,'JarBoxBuildCommit':'a'}))
            self.assertEqual(verify_ipa(p,'a','headless-reconstructed'),rebuilt_profile)
            with self.assertRaises(ValueError):
                verify_ipa(p,'a','headless-render-gc')
            with self.assertRaises(ValueError):
                verify_ipa(p,'a','headless-render')
            with self.assertRaises(ValueError):
                verify_ipa(p,'a','headless')

    def test_archive(self):
        profile = 'const-arith-0_const-branch-0_decoded-int-0_event-sleep-0_paint-qos-0_ninja-core-0_core-aba-0_array-mode1-1_char-leaf-1_binary-sprite-0_residual-0_block-ir-0_render-island-0_gc-index-0_reconstruct-0'
        with tempfile.TemporaryDirectory() as d:
            p = Path(d) / 'test.ipa'
            for actual, sha, extra in [(profile, 'a', False), (profile.replace('core-aba-0','core-aba-1'), 'a', False), (profile, 'b', False), (profile, 'a', True), (profile+'_char-leaf-0','a',False), (profile.replace('block-ir-0','block-ir-1'),'a',False)]:
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
