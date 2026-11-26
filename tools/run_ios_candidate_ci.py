"""Run the checked-in Codemagic build on a macOS CI runner, not a release."""
import argparse
import os
import plistlib
import re
import subprocess
from pathlib import Path
from zipfile import ZipFile

ROOT = Path(__file__).resolve().parents[1]
CANDIDATES = ('JARBOX_VM_ARRAY_LOOKUP_MODE1_EXPERIMENT', 'JARBOX_VM_CHAR_LEAF_EXPERIMENT')
OFF = ('JARBOX_VM_ARRAY_LOOKUP_EXPERIMENT', 'JARBOX_VM_ARRAY_LOOKUP_DIAGNOSTIC',
       'JARBOX_NINJA_CORE_EXPERIMENT', 'JARBOX_CORE_ABA', 'JARBOX_PAINT_QOS_EXPERIMENT',
       'JARBOX_VM_PERF_CANDIDATE', 'JARBOX_VM_DECODED_INT_EXPERIMENT',
       'JARBOX_VM_EVENT_SLEEP_EXPERIMENT', 'JARBOX_VM_CONST_ARITH_FUSION_EXPERIMENT',
       'JARBOX_VM_CONST_BRANCH_FUSION_EXPERIMENT')
IPA = 'J2ME-Treo-jar-cpu-audit-unsigned.ipa'


def prepare(config, configuration, environ):
    if configuration not in ('control', 'intrinsics'):
        raise ValueError('invalid configuration')
    workflow = config['workflows']['jit-probe-unsigned']
    variables = workflow['environment']['vars']
    if not all(re.fullmatch(r'JARBOX_[A-Z0-9_]+', k) and isinstance(v, str)
               for k, v in variables.items()):
        raise ValueError('unexpected build variables')
    for k in CANDIDATES + OFF:
        if variables.get(k) != '0':
            raise ValueError('unexpected default: ' + k)
    scripts = workflow['scripts']
    if len(scripts) != 1 or scripts[0]['name'] != 'Build and package unsigned iPhone IPA':
        raise ValueError('build recipe changed; review runner')
    script = scripts[0]['script']
    if not isinstance(script, str) or not script.startswith('set -euo pipefail'):
        raise ValueError('invalid build recipe')
    env = {k: v for k, v in environ.items() if not k.startswith('JARBOX_')}
    env.update(variables)
    for k in CANDIDATES:
        env[k] = '1' if configuration == 'intrinsics' else '0'
    return script, env


def verify_ipa(path, commit, configuration):
    with ZipFile(path) as z:
        names = [n for n in z.namelist() if re.fullmatch(r'Payload/[^/]+\.app/Info\.plist', n)]
        if len(names) != 1:
            raise ValueError('expected exactly one packaged app')
        info = plistlib.loads(z.read(names[0]))
    if info.get('JarBoxBuildCommit') != commit:
        raise ValueError('packaged commit mismatch')
    profile = info.get('JarBoxPerfProfile', '').split('_')
    enabled = '1' if configuration == 'intrinsics' else '0'
    for key, value in [('array-mode1', enabled), ('char-leaf', enabled),
                       ('core-aba', '0'), ('ninja-core', '0'), ('paint-qos', '0'),
                       ('decoded-int', '0'), ('event-sleep', '0'),
                       ('const-arith', '0'), ('const-branch', '0')]:
        if [p for p in profile if p.startswith(key + '-')] != [key + '-' + value]:
            raise ValueError('packaged profile mismatch: ' + key)
    return info['JarBoxPerfProfile']


def main():
    import yaml
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--configuration', choices=('control', 'intrinsics'), default='intrinsics')
    p.add_argument('--plan', action='store_true', help='validate recipe and print switches only')
    a = p.parse_args()
    script, env = prepare(yaml.safe_load((ROOT / 'codemagic.yaml').read_text()), a.configuration, os.environ)
    subprocess.run(['bash', '-n'], input=script, text=True, check=True)
    for key in CANDIDATES + OFF:
        print(f'{key}={env[key]}', flush=True)
    if a.plan:
        return
    if os.uname().sysname != 'Darwin':
        raise SystemExit('iOS build requires macOS')
    commit = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip()
    subprocess.run(['bash', '-c', script], cwd=ROOT, env=env, check=True)
    print('Verified packaged profile:', verify_ipa(ROOT / IPA, commit, a.configuration))


if __name__ == '__main__':
    main()
