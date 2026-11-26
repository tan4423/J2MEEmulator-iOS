#!/usr/bin/env python3
"""Offline def-use residual plans for straight-line Ninja draw wrappers.
Not executable VM code: conditional on an exact bundled headless Canvas sink.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
import zipfile
from ninja_paint_slice import G, argc, kind, member, parse, pure_stack, label

# No field read is erased, even if its value becomes dead. Keep resolution,
# initialization, null checks and volatile ordering. No branch or handler.
SAFE_DRAWS = {'drawLine':'(IIII)V','drawRect':'(IIII)V','fillRect':'(IIII)V',
              'drawRoundRect':'(IIIIII)V','fillRoundRect':'(IIIIII)V',
              'drawImage':'(Ljavax/microedition/lcdui/Image;III)V',
              'drawRegion':'(Ljavax/microedition/lcdui/Image;IIIIIIII)V',
              'drawArc':'(IIIIII)V','fillArc':'(IIIIII)V'}
LOCAL = re.compile(r'([ia])(load|store)(?:_([0-3]))?$')


def plan(key, method):
    if method['handlers'] or method['switch_targets'] or ' synchronized ' in ' '+method['decl']+' ' or not key[2].endswith(')V'):
        return None
    ins=method['ins']; stack=[]; locals_={}; deps={}; mandatory=set(); reads=[]; call=None
    if not ins or ins[-1][1]!='return':
        return None
    def take(n):
        if len(stack)<n: raise ValueError('stack underflow')
        values=stack[-n:] if n else []
        if n: del stack[-n:]
        return values
    try:
        for i,(pc,op,arg) in enumerate(ins):
            if call is not None and op!='return': return None
            m=LOCAL.fullmatch(op)
            if m:
                slot=int(m[3] if m[3] is not None else arg.split()[0]); loc=slot
                if m[2]=='load':
                    prior=locals_.get(loc); deps[i]=[prior] if prior is not None else []; stack.append(i)
                else:
                    deps[i]=take(1); locals_[loc]=i
            elif op in ('getfield','getstatic'):
                ref=member(key[0],arg)
                if not ref or ref[2] not in ('I','Z','B','C','S','L'+G+';'): return None
                deps[i]=take(1 if op=='getfield' else 0); stack.append(i); mandatory.add(i)
                reads.append({'pc':pc,'opcode':op,'field':label(ref)})
            elif op=='invokevirtual':
                ref=member(key[0],arg)
                if not ref or ref[0]!=G or SAFE_DRAWS.get(ref[1])!=ref[2]: return None
                n=argc(ref[2]); values=take(n+1)
                if stack: return None
                # The guard consumes the already-evaluated receiver, never
                # reloads the field. On miss materialize original args from
                # saved inputs/read values and invoke the original method.
                deps[i]=values[:1]; mandatory.add(i)
                call={'pc':pc,'target':label(ref),'receiver_pc':ins[values[0]][0],
                      'argument_roots':[ins[x][0] for x in values[1:]]}
            elif op=='return':
                if i!=len(ins)-1 or stack or call is None: return None
                deps[i]=[]; mandatory.add(i)
            else:
                n=pure_stack(op,arg)
                if n is None: return None
                deps[i]=take(n); stack.append(i)
    except (ValueError,IndexError,TypeError):
        return None
    live=set(); todo=list(mandatory)
    while todo:
        i=todo.pop()
        if i not in live:
            live.add(i); todo.extend(deps[i])
    dead=[ins[i][0] for i in range(len(ins)) if i not in live]
    return {'method':label(key),'instructions':len(ins),'ordered_reads':reads,
            'guarded_call':call,'retain_pcs':[ins[i][0] for i in sorted(live)],
            'conditional_dead_pcs':dead,'conditional_dead_count':len(dead),
            'dependencies':{str(ins[i][0]):[ins[j][0] for j in parents] for i,parents in deps.items()},
            'status':'conditional_ir_only','runtime_authorized':False}


def analyze(path, inventory):
    with zipfile.ZipFile(path) as z:
        names=[x.filename for x in z.infolist() if x.filename.endswith('.class')]
        if not names or len(names)>2000 or len(set(names))!=len(names) or sum(z.getinfo(n).file_size for n in names)>64*1024*1024:
            raise ValueError('archive outside analysis limits')
        owners=sorted({x.split('.',1)[0] for x in inventory['draw_wrapper_candidates']})
        if hashlib.sha256(path.read_bytes()).hexdigest()!=inventory['sha256']: raise ValueError('inventory SHA mismatch')
        if not owners: return {'jar':path.name,'sha256':inventory['sha256'],'plans':[]}
        raw=subprocess.run(['javap','-classpath',str(path),'-p','-s','-c',*[x.replace('/','.') for x in owners]],capture_output=True,text=True,check=True,timeout=60)
        _, methods=parse(raw.stdout); wanted=set(inventory['draw_wrapper_candidates']); plans=[]; rejected=[]
        for key,m in sorted(methods.items()):
            if label(key) not in wanted: continue
            p=plan(key,m)
            if p is None: rejected.append(label(key)); continue
            p['class_sha256']=hashlib.sha256(z.read(key[0]+'.class')).hexdigest(); plans.append(p)
        found={p['method'] for p in plans}|set(rejected)
        rejected.extend(sorted(wanted-found))
        return {'jar':path.name,'sha256':inventory['sha256'],'plans':plans,'rejected':rejected,
                'static_dead_instructions':sum(p['conditional_dead_count'] for p in plans),
                'static_wrapper_instructions':sum(p['instructions'] for p in plans),
                'ordered_field_reads':sum(len(p['ordered_reads']) for p in plans),
                'runtime_authorized':False}


def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('jars',nargs='+',type=Path);p.add_argument('--inventory',type=Path,required=True);p.add_argument('--output',type=Path,required=True);a=p.parse_args()
    inv={x['sha256']:x for x in json.loads(a.inventory.read_text())['jars']}
    out=[analyze(x,inv[hashlib.sha256(x.read_bytes()).hexdigest()]) for x in a.jars]
    a.output.write_text(json.dumps({'format':'jarbox-wrapper-residual-v1','jars':out},indent=2)+'\n')
if __name__=='__main__':main()
