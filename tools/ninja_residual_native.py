#!/usr/bin/env python3
"""Emit a pointer-free host residual plan; no runtime authorization for games."""
import argparse
import re
import struct
from pathlib import Path
import ninja_map_residual as ir

# Encode the exact subset already accepted by the typed CFG compiler.
OP = dict(bipush=0x10,sipush=0x11,aload_0=0x2a,dup=0x59,iinc=0x84,
          getstatic=0xb2,putstatic=0xb3,invokestatic=0xb8,invokevirtual=0xb6,
          iadd=0x60,isub=0x64,imul=0x68,iand=0x7e,ishr=0x7a,idiv=0x6c,irem=0x70,
          caload=0x34,if_icmpeq=0x9f,if_icmpne=0xa0,if_icmpge=0xa2,goto=0xa7,return_=0xb1)
OP.update({f'iconst_{i}':3+i for i in range(6)},iconst_m1=2)
OP.update({f'iload_{i}':0x1a+i for i in range(1,4)})
OP.update({f'istore_{i}':0x3b+i for i in range(1,4)})
CP_OPS={'getstatic','putstatic','invokestatic','invokevirtual'}
BRANCHES={'if_icmpeq','if_icmpne','if_icmpge','goto'}


def encode(ins, order):
    """Expected raw/converted bytes; class_load.c converts only u16 operands here."""
    out=bytearray()
    for pc,op,arg in ins:
        if pc!=len(out):raise ValueError('instruction boundary')
        out.append(OP['return_' if op=='return' else op])
        if op in CP_OPS:
            out.extend(struct.pack(order+'H',int(re.match(r'#(\d+)',arg)[1])))
        elif op in BRANCHES:
            out.extend(struct.pack(order+'h',int(arg.split()[0])-pc))
        elif op=='sipush':out.extend(struct.pack(order+'h',int(arg.split()[0])))
        elif op=='bipush':out.extend(struct.pack('b',int(arg.split()[0])))
        elif op=='iinc':
            idx,value=map(int,arg.split(','));out.extend(struct.pack('Bb',idx,value))
    return bytes(out)


def slot(v):
    if v in ('l1','l2','l3'):return int(v[1:])
    if not re.fullmatch(r'[sr](?:[0-9]|1[01])',v):raise ValueError('unknown slot')
    return (16 if v[0]=='r' else 4)+int(v[1:])


def emit(ins,entry,plan,resume=False,resolved_reads=False):
    """One node per retained IR operation. Effects delegate at original PC."""
    table={p:(o,a) for p,o,a in ins}
    order=[entry]+sorted(set(plan)-{entry});index={p:i for i,p in enumerate(order)}
    if len(order)>=65535:raise ValueError('plan too large')
    rows=[]
    for pc in order:
        node=plan[pc];op,arg=table[pc];uses=sorted(node.uses,key=lambda v:int(v[1:]));defs=node.defs
        if len(uses)>2 or len(defs)>1 or len(node.successors)>2:raise ValueError('node shape')
        a,b=(list(map(slot,uses))+[255,255])[:2];dst=slot(next(iter(defs))) if defs else 255
        nxt,alt=([index[x] for x in node.successors]+[65535,65535])[:2]
        imm=0;length=0
        if not node.code:
            if node.effect or node.branch or len(node.successors)!=1:raise ValueError('empty effect')
            kind='JBR_NOP'
        elif node.effect or op=='getstatic':
            if op not in ('getstatic','putstatic','caload','invokestatic','invokevirtual','idiv','irem','return'):raise ValueError('effect op')
            kind='JBR_EFFECT';length=3 if op in CP_OPS else 1
            imm=OP['return_' if op=='return' else op]
        elif op.startswith('iconst_') or op in ('bipush','sipush'):
            kind='JBR_CONST';imm=(-1 if op=='iconst_m1' else int(op[-1])) if op.startswith('iconst_') else int(arg.split()[0])
        elif op=='aload_0':kind='JBR_MOVE';a=0
        elif op.startswith(('iload_','istore_')) or op=='dup':kind='JBR_MOVE'
        elif op=='iinc':kind='JBR_INC';imm=int(arg.split(',')[1])
        elif op in ('iadd','isub','imul','iand','ishr','if_icmpeq','if_icmpne','if_icmpge'):
            kind='JBR_'+op.upper()
        else:raise ValueError('unsupported node '+op)
        if kind!='JBR_EFFECT' and len(node.successors)!=(2 if node.branch else 1):raise ValueError('successor shape')
        checkpoint=int(resume and op=='aload_0')
        rows.append(f'    {{{kind},{a},{b},{dst},{pc},{nxt},{alt},{length},{checkpoint},{imm}}},')
    code=encode(ins,'<')
    if len(code)>=65535:raise ValueError('code too large')
    return ('/* Generated host fixture only; no pointer or mutable VM state. */\n'
            f'static const int jbr_draw_effects = {int(any(o.effect and table[p][0]=="invokevirtual" for p,o in plan.items()))};\n'+
            f'static const int jbr_resume = {int(resume)};\n'+
            f'static const int jbr_resolved_reads = {int(resolved_reads)};\n'+
            'static const unsigned char jbr_expected_code[] = {\n'+
            '\n'.join('    '+','.join(str(x) for x in code[i:i+24])+',' for i in range(0,len(code),24))+
            '\n};\nstatic const JarBoxResidualOp jbr_plan[] = {\n'+'\n'.join(rows)+'\n};\n')


def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('original',type=Path);p.add_argument('header',type=Path);p.add_argument('--draw-effects',action='store_true');p.add_argument('--resume',action='store_true');p.add_argument('--resolved-reads',action='store_true');a=p.parse_args()
    if a.resume and not a.draw_effects:raise ValueError('resume requires draw effects')
    ins=ir.disassemble(a.original);ops,fields,_=ir.lower(ins,draw_effects=a.draw_effects)
    if a.resolved_reads:
        if not a.draw_effects:raise ValueError('resolved reads require draw effects')
        # Synthetic fixture: warmup takes r3==4, not r3==9. b20 is volatile.
        # Independent expectation; the C compiler must prove the actual metadata.
        plain={f for f in fields if f[1] in ('I','B') and f[0] not in ('Class_hac.b20','Class_hxb.s5')}
        ops,_,_=ir.lower(ins,draw_effects=True,plain_reads=plain)
    checkpoints={pc for pc,op,_ in ins if op=='aload_0'} if a.resume else set()
    # Test oracle: every admitted draw block starts with aload_0 on an
    # empty stack and all three original int locals are initialized.
    # C independently verifies this before compiling any checkpoint.
    for pc in checkpoints:ops[pc].uses.update(('l1','l2','l3'))
    entry,plan=ir.reduce(ops)
    if not checkpoints<=set(plan):raise ValueError('lost resume checkpoint')
    for pc in checkpoints:plan[pc].uses.difference_update(('l1','l2','l3'))
    if a.resolved_reads:
        removed={pc for pc,op,arg in ins if op=='getstatic' and pc not in plan}
        retained={pc for pc,op,arg in ins if op=='getstatic' and ('Class_hac.b20:' in arg or 'Class_hxb.s5:' in arg)}
        if not removed or not retained or not retained<=set(plan):raise ValueError('vacuous read policy')
        print('resolved-read fixture: removed',len(removed),'read sites; mandatory',len(retained))
    a.header.write_text(emit(ins,entry,plan,a.resume,a.resolved_reads));print('native residual plan:',len(plan),'nodes; checkpoints:',len(checkpoints))
if __name__=='__main__':main()
