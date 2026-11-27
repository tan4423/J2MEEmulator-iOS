#!/usr/bin/env python3
"""Read-only Ninja headless corpus audit. Metadata only; never authorizes elision."""
import argparse
from collections import Counter
import hashlib
import json
from pathlib import Path
import re
import subprocess
import zipfile

G = '(Ljavax/microedition/lcdui/Graphics;)V'
# Separate archive identities from game families. Both Nick archives have the
# same classes, but a repack does not become trusted by name alone.
PROFILES = {
    'nick-t5': dict(hashes=['11b1d4c11f9082b9d07bc7bd92a9ad3abad40764853e23686cc86686869c966c',
                            '1e79927643228d369c1f590879bdefe2051820080606dd433db7da349028b9f9'],
                    canvas='Class_hef', delegate='Class_bs', paint_pc=5, main='Class_hxb',
                    character='Class_hda', wrapper='Class_hvi', skill='a0', field='s6',
                    write=1424, update='n1', read=272, service='Class_hgh', send='r', send_pc=288,
                    queue='Class_hhh.a:(LClass_bk;)V', queue_pc=30),
    'original-251': dict(hashes=['96f811dc1317ec41ba01953350436dc8f850090c3018a26b4ae35f3124c2e95d'],
                    canvas='main.b', delegate='main.c', paint_pc=5, main='main.a',
                    character='bp', wrapper='t', skill='a', field='cV',
                    write=1440, update='J', read=273, service='dq', send='r', send_pc=289,
                    queue='dh.a:(Lce;)V', queue_pc=30),
    'trung-217': dict(hashes=['3420df8cb91bcc33852230d1c6f9166a99d6ce3f2c4a332cf1bad851c3f7b276'],
                    canvas='Class_ek', delegate='Class_bv', paint_pc=5, main='Class_cu',
                    character='Class_bb', wrapper='Class_gp', skill='a', field='ii',
                    write=1631, update='al', read=330, service='Class_fp', send='r', send_pc=350,
                    queue='Class_fq.a:(LClass_bo;)V', queue_pc=34),
    'v9-x1': dict(hashes=['c48f8e40e8c619a8503626b14940693d3fd37f1ecbba1c1342f53957d42f0080'],
                    canvas='cu', delegate='am', paint_pc=12, main='bj',
                    character='Q', wrapper='eg', skill='a', field='cQ',
                    write=1482, update='aZ', read=289, service='du', send='iC', send_pc=322,
                    queue='dv.X:(Lcj;)V', queue_pc=30),
}


def digest(data):
    return hashlib.sha256(data).hexdigest()


def identify(sha):
    for name, p in PROFILES.items():
        if sha in p['hashes']:
            return name, p
    raise ValueError('unrecognized archive; no headless authorization')


def parse(text):
    methods = {}
    cls = decl = key = None
    active = False
    for line in text.splitlines():
        m = re.match(r'^(?:[\w-]+ )*(?:class|interface) (\S+).*\{$', line)
        if m:
            cls = m[1]; key = None; active = False
        elif line.startswith('  ') and not line.startswith('   '):
            decl = line; key = None; active = False
        elif cls and decl and line.startswith('    descriptor: ('):
            name = decl.split('(')[0].split()[-1] if '(' in decl else '<clinit>'
            if name == cls and all(x in ('public','private','protected','synthetic') for x in decl.split('(')[0].split()[:-1]):
                name = '<init>'
            key = (cls, name, line.split()[-1])
            if key in methods:
                raise ValueError('duplicate method '+str(key))
            methods[key] = []
        elif key and line.strip() == 'Code:':
            active = True
        elif active and line.strip() == 'Exception table:':
            active = False
        elif active:
            m = re.match(r'^\s+(\d+):\s+([a-z][a-z0-9_]*)\s*(.*)', line)
            if m:
                methods[key].append((int(m[1]), m[2], m[3]))
    return methods


def symbol(owner, arg):
    m = re.search(r'// (?:InterfaceMethod|Method|Field) (.+?):(\S+)', arg)
    if not m:
        return None
    name, desc = m.groups()
    if '.' not in name:
        name = owner+'.'+name
    return name.replace('/', '.')+':'+desc


def require(methods, key, pc, op, target):
    matches = [(o, symbol(key[0], a)) for p, o, a in methods[key] if p == pc]
    if matches != [(op, target)]:
        raise ValueError(f'witness mismatch: {key} PC{pc}: {matches} != {(op, target)}')
    return dict(method=list(key), pc=pc, opcode=op, symbol=target)


def effects(code):
    out = Counter()
    for pc, op, arg in code:
        out['instructions'] += 1
        if op in ('getfield', 'getstatic'):
            out['field_reads'] += 1
        if op in ('putfield', 'putstatic') or re.fullmatch(r'[ialfdbcs]astore', op):
            out['writes'] += 1
        if op.startswith('invoke'):
            out['calls'] += 1
        if op in ('new', 'newarray', 'anewarray', 'multianewarray'):
            out['allocations'] += 1
        if op in ('monitorenter', 'monitorexit'):
            out['monitor_ops'] += 1
        if op in ('idiv','irem','ldiv','lrem','athrow','checkcast','arraylength','getfield','putfield') or re.fullmatch(r'[ialfdbcs]aload', op):
            out['explicit_fault_sites'] += 1
        if (op.startswith('if') or op in ('goto','goto_w')) and arg.split() and int(arg.split()[0]) <= pc:
            out['backedges'] += 1
    return dict(sorted(out.items()))


def audit(path, javap='javap'):
    sha = digest(path.read_bytes())
    family, p = identify(sha)
    with zipfile.ZipFile(path) as z:
        entries = sorted(n for n in z.namelist() if n.endswith('.class'))
        if not entries or len(entries) != len(set(entries)) or any(not re.fullmatch(r'[A-Za-z0-9_$/]+\.class', n) for n in entries):
            raise ValueError('unsupported class archive')
        class_hashes = {n: digest(z.read(n)) for n in entries}
    code = subprocess.check_output([javap,'-classpath',str(path.resolve()),'-p','-c','-s',*[n[:-6].replace('/','.') for n in entries]], text=True, timeout=180)
    methods = parse(code)
    c = p['character']; field = c+'.'+p['field']+':I'
    skill = (c,p['skill'],'(L'+p['wrapper']+';)V')
    update = (c,p['update'],'()V')
    send = (p['service'],p['send'],'()V')
    paint = (p['canvas'],'paint',G)
    main = (p['main'],'run','()V')
    witnesses = [require(methods,paint,p['paint_pc'],'invokevirtual',p['delegate']+'.a:'+G),
                 require(methods,skill,p['write'],'putfield',field),
                 require(methods,update,p['read'],'getfield',field),
                 require(methods,update,p['send_pc'],'invokevirtual',p['service']+'.'+p['send']+':()V'),
                 require(methods,send,p['queue_pc'],'invokevirtual',p['queue'])]
    body = methods[skill]
    at = next(i for i, x in enumerate(body) if x[0] == p['write'])
    if at < 6 or body[at-1][1] != 'iadd' or not any(o=='getfield' and symbol(c,a)==field for _,o,a in body[at-6:at-1]):
        raise ValueError('skill increment shape changed')
    writes = [dict(method=list(k),pc=pc) for k,body in sorted(methods.items()) for pc,op,arg in body if op=='putfield' and symbol(k[0],arg)==field]
    return dict(family=family, archive_sha256=sha, classes=len(entries),
                class_set_sha256=digest(json.dumps(class_hashes,sort_keys=True,separators=(',',':')).encode()),
                methods=len(methods), witness=witnesses, skill_writes=writes,
                roots=[dict(method=list(k),effects=effects(methods[k])) for k in (paint,main,skill,update,send)],
                runtime_authorized=False)


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('archives',nargs='+',type=Path)
    args = p.parse_args()
    print(json.dumps([audit(path) for path in args.archives],indent=2,sort_keys=True))


if __name__ == '__main__':
    main()
