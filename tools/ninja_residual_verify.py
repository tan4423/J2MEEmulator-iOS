#!/usr/bin/env python3
"""Typed wrapper IR and differential MODEL, not MiniJVM or runtime authorization."""
import argparse
import hashlib
import json
from pathlib import Path
import random
import re
import subprocess
from ninja_paint_slice import G, member, parse, label
from ninja_wrapper_residual import SAFE_DRAWS, LOCAL, plan

I, R = 'I', 'R'

def types(desc):
    if not desc.startswith('(') or not desc.endswith(')V'):
        raise ValueError('unsupported descriptor')
    body=desc[1:-2]; args=[]
    while body:
        m=re.match(r'(I|L[^;]+;)',body)
        if not m: raise ValueError('unsupported argument type')
        args.append(I if m[1]=='I' else R); body=body[len(m[1]):]
    return args


def compile_ir(key,m):
    # Deliberately narrower than the census: only actual observed operations.
    if not plan(key,m) or not m['decl'].startswith('public final void '):
        raise ValueError('not a supported wrapper')
    slots=[R]+types(key[2]); local={i:(-i-1,t) for i,t in enumerate(slots)}
    nodes=[]; stack=[]; call=None; prior=-1
    def pop(t):
        if not stack or stack[-1][1]!=t: raise ValueError('stack type mismatch')
        return stack.pop()[0]
    def emit(pc,op,t,args=(),value=None):
        idx=len(nodes); nodes.append((pc,op,t,tuple(args),value)); return idx
    for pc,op,arg in m['ins']:
        if pc<=prior: raise ValueError('non-increasing pc')
        prior=pc
        if call is not None and op!='return': raise ValueError('after call')
        match=LOCAL.fullmatch(op)
        if match:
            t=I if match[1]=='i' else R
            n=int(match[3] if match[3] is not None else arg.split()[0])
            if not 0<=n<64: raise ValueError('local range')
            if match[2]=='load':
                if n not in local or local[n][1]!=t: raise ValueError('local type')
                stack.append((emit(pc,'load',t,[local[n][0]]),t))
            else: local[n]=(emit(pc,'store',t,[pop(t)]),t)
        elif op in ('getstatic','getfield'):
            ref=member(key[0],arg)
            if not ref or ref[2] not in ('I','L'+G+';'): raise ValueError('field type')
            t=I if ref[2]=='I' else R
            args=[pop(R)] if op=='getfield' else []
            stack.append((emit(pc,op,t,args,ref),t))
        elif op=='imul':
            b,a=pop(I),pop(I);stack.append((emit(pc,op,I,[a,b]),I))
        elif op in ('iconst_0','sipush'):
            v=0 if op=='iconst_0' else int(arg.split()[0])
            if not -32768<=v<=32767: raise ValueError('constant range')
            stack.append((emit(pc,'const',I,value=v),I))
        elif op=='invokevirtual':
            ref=member(key[0],arg)
            if not ref or ref[0]!=G or SAFE_DRAWS.get(ref[1])!=ref[2]: raise ValueError('sink target')
            args=[pop(t) for t in reversed(types(ref[2]))][::-1]; receiver=pop(R)
            if stack: raise ValueError('extra operand')
            call=emit(pc,'call',None,[receiver]+args,ref)
        elif op=='return':
            if call is None or stack or pc!=m['ins'][-1][0]: raise ValueError('return')
            emit(pc,'return',None)
        else: raise ValueError('unsupported opcode '+op)
    if call is None: raise ValueError('missing call')
    return nodes,slots


def int32(v): return (v+2**31)%2**32-2**31


class Fault(Exception): pass


class World:
    """Deterministic effect model. No Java objects or native renderer executed."""
    def __init__(self,scales,receiver,owner=1,context=10,fail_read=-1,fail_call=False):
        self.scales=list(scales);self.receiver=receiver;self.owner=owner;self.context=context
        self.fail_read=fail_read;self.fail_call=fail_call;self.events=[];self.reads=0;self.work=0
    def read(self,pc,op,ref,obj):
        self.events.append(('read',pc,op,ref,obj));n=self.reads;self.reads+=1
        if n==self.fail_read: raise Fault('field-resolution')
        if op=='getfield' and obj is None: raise Fault('null-field')
        return self.scales[n%len(self.scales)] if ref[2]=='I' else self.receiver
    def resolve(self,pc,ref,receiver):
        self.events.append(('resolve',pc,ref,receiver))
        if self.fail_call: raise Fault('method-resolution')
        if receiver is None: raise Fault('null-call')
        return receiver==('Canvas',self.owner,self.context,True,True)
    def draw(self,pc,ref,receiver,args):
        self.events.append(('draw',pc,ref,receiver,tuple(args)))


def execute(nodes,slots,inputs,world,residual):
    if len(inputs)!=len(slots): raise ValueError('input arity')
    values={-i-1:v for i,v in enumerate(inputs)}
    def get(n):
        if n in values: return values[n]
        _,op,_,args,v=nodes[n]
        if op in ('load','store'): out=get(args[0])
        elif op=='const': out=v
        elif op=='imul': out=int32(get(args[0])*get(args[1]))
        else: raise AssertionError('effect must execute eagerly')
        world.work+=1;values[n]=out;return out
    try:
        for n,(pc,op,t,args,v) in enumerate(nodes):
            if op in ('getstatic','getfield'):
                values[n]=world.read(pc,op,v,get(args[0]) if args else None)
            elif op=='call':
                receiver=get(args[0]); skip=world.resolve(pc,v,receiver)
                if not residual or not skip:
                    actual=[get(a) for a in args[1:]]
                    if not skip: world.draw(pc,v,receiver,actual)
            elif op=='return': world.events.append(('return',pc))
            elif not residual: get(n)
    except Fault as ex: world.events.append(('exception',str(ex)))
    return world.events,world.work


def verify_jar(path,inventory,trials=1000):
    if hashlib.sha256(path.read_bytes()).hexdigest()!=inventory['sha256']: raise ValueError('archive mismatch')
    owners=sorted({x['method'].split('.',1)[0] for x in inventory['plans']})
    raw=subprocess.check_output(['javap','-classpath',str(path),'-p','-s','-c',*owners],text=True,timeout=60)
    _,methods=parse(raw);by_label={label(k):(k,m) for k,m in methods.items()}; rng=random.Random(20261126)
    counts={'wrappers':0,'cases':0,'headless_cases':0,'headless_eager_pure_ops':0,'headless_residual_pure_ops':0,'fault_cases':0,'offscreen_or_guard_miss_cases':0}
    for p in inventory['plans']:
        key,m=by_label[p['method']]; nodes,slots=compile_ir(key,m);counts['wrappers']+=1
        for i in range(trials):
            # Include changing scale reads, overflow, wrong owner/context,
            # subclass/ABI guard miss, null receiver and resolution failures.
            receivers=[('Canvas',1,10,True,True),('Image',1,10,True,True),('Canvas',2,10,True,True),('Canvas',1,11,True,True),('Canvas',1,10,False,True),('Canvas',1,10,True,False),None]
            rc=receivers[i%len(receivers)]; fail_read=(i//7)%8-1 if i%5==0 else -1;fail_call=i%13==0
            scales=[rng.randrange(-2**31,2**31) for _ in range(8)]
            inputs=['wrapper']+[rng.randrange(-2**31,2**31) if t==I else ('image',i) for t in slots[1:]]
            a,b=World(scales,rc,fail_read=fail_read,fail_call=fail_call),World(scales,rc,fail_read=fail_read,fail_call=fail_call)
            x,y=execute(nodes,slots,inputs,a,False),execute(nodes,slots,inputs,b,True)
            if x[0]!=y[0]: raise AssertionError((key,i,x,y))
            counts['cases']+=1
            if x[0][-1][0]=='exception':counts['fault_cases']+=1
            elif rc==receivers[0]:
                counts['headless_cases']+=1;counts['headless_eager_pure_ops']+=x[1];counts['headless_residual_pure_ops']+=y[1]
            else: counts['offscreen_or_guard_miss_cases']+=1
    return {'jar':path.name,**counts,'runtime_authorized':False,'test_kind':'typed IR differential effect model, not MiniJVM'}


def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('jars',nargs='+',type=Path);p.add_argument('--plans',required=True,type=Path);p.add_argument('--output',required=True,type=Path);p.add_argument('--trials',type=int,default=1000);a=p.parse_args()
    if not 1<=a.trials<=100000: p.error('trials outside limit')
    inv={x['sha256']:x for x in json.loads(a.plans.read_text())['jars']}
    results=[verify_jar(x,inv[hashlib.sha256(x.read_bytes()).hexdigest()],a.trials) for x in a.jars]
    a.output.write_text(json.dumps(results,indent=2)+'\n')
if __name__=='__main__':main()
