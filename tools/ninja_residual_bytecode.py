#!/usr/bin/env python3
"""Executable test-only stack-slot residual backend; never changes a game JAR.

The compiler accepts the existing typed map IR. Output is a temporary class
fixture with original constant pool, not a production VM admission decision.
"""
import re
import struct
from pathlib import Path


def emit_bytecode(ins, entry, residual):
    """Lower retained operations to ordinary JVM bytecode plus original-PC map.

    Slots are local variables in the fixture, so original effect instructions
    execute in the ordinary interpreter. Primitive and reference slots never
    alias. Reference locals may extend lifetime: not a live runtime overlay.
    """
    table = {pc: (op, arg) for pc, op, arg in ins}
    if len(table) != len(ins) or entry not in residual or not set(residual) <= set(table):
        raise ValueError('bad plan identity')
    out = bytearray()
    labels = {}
    fixups = []
    pc_map = []
    max_local = 28

    def slot(v):
        if v in ('l1', 'l2', 'l3'):
            return int(v[1:]), False
        if not re.fullmatch(r'[sr](?:[0-9]|1[01])', v):
            raise ValueError('unknown slot ' + v)
        return (16 if v[0] == 'r' else 4) + int(v[1:]), v[0] == 'r'

    def access(v, store=False):
        idx, ref = slot(v)
        out.extend(( (0x3a if ref else 0x36) if store else (0x19 if ref else 0x15), idx))

    def stack_slots(values):
        if any(not v.startswith(('s', 'r')) for v in values):
            raise ValueError('nonstack operand')
        return sorted(values, key=lambda v: int(v[1:]))

    def single(values):
        if len(values) != 1:
            raise ValueError('expected single slot')
        return next(iter(values))

    def cp(arg):
        m = re.match(r'#(\d+)\b', arg)
        if not m or not 0 < int(m[1]) < 65536:
            raise ValueError('constant pool operand')
        return struct.pack('>H', int(m[1]))

    def jump(op, target):
        fixups.append((len(out), target))
        out.extend((op, 0, 0))

    order = [entry] + sorted(set(residual) - {entry})
    binary = dict(iadd=0x60, isub=0x64, imul=0x68, idiv=0x6c, irem=0x70,
                  ishr=0x7a, iand=0x7e, caload=0x34)
    branches = dict(if_icmpeq=0x9f, if_icmpne=0xa0, if_icmpge=0xa2)
    for i, pc in enumerate(order):
        o = residual[pc]
        op, arg = table[pc]
        nxt = order[i + 1] if i + 1 < len(order) else None
        labels[pc] = len(out)
        if any(q not in residual for q in o.successors):
            raise ValueError('missing target')
        if o.code:
            if op.startswith('iconst_') or op in ('bipush', 'sipush'):
                if op.startswith('iconst_'):
                    out.append(2 if op == 'iconst_m1' else 3 + int(op[-1]))
                else:
                    out.append(0x10 if op == 'bipush' else 0x11)
                    out.extend(struct.pack('>b' if op == 'bipush' else '>h', int(arg.split()[0])))
                access(single(o.defs), True)
            elif op.startswith(('iload_', 'istore_')) or op == 'dup':
                access(single(o.uses)); access(single(o.defs), True)
            elif op == 'aload_0':
                out.append(0x2a); access(single(o.defs), True)
            elif op == 'iinc':
                idx, value = map(int, arg.split(','))
                out.extend((0x84, idx)); out.extend(struct.pack('>b', value))
            elif op == 'getstatic':
                pc_map.append((len(out), pc)); out.append(0xb2); out.extend(cp(arg))
                access(single(o.defs), True)
            elif op == 'putstatic':
                access(single(o.uses)); pc_map.append((len(out), pc))
                out.append(0xb3); out.extend(cp(arg))
            elif op == 'invokevirtual':
                operands=stack_slots(o.uses)
                if len(operands)!=2 or any(not v.startswith('r') for v in operands) or o.defs:
                    raise ValueError('draw effect operands')
                for v in operands: access(v)
                out.extend((3,)*8)
                pc_map.append((len(out),pc));out.append(0xb6);out.extend(cp(arg))
            elif op in binary or op == 'invokestatic':
                operands = stack_slots(o.uses)
                if len(operands) != 2:
                    raise ValueError('binary operands')
                for v in operands: access(v)
                pc_map.append((len(out), pc))
                if op == 'invokestatic':
                    out.append(0xb8); out.extend(cp(arg))
                else: out.append(binary[op])
                access(single(o.defs), True)
            elif op in branches and o.branch:
                operands = stack_slots(o.uses)
                if len(operands) != 2 or len(o.successors) != 2:
                    raise ValueError('branch operands')
                for v in operands: access(v)
                jump(branches[op], o.successors[0])
                if o.successors[1] != nxt: jump(0xa7, o.successors[1])
                continue
            elif op == 'return' and not o.successors:
                pc_map.append((len(out), pc)); out.append(0xb1)
                continue
            else:
                raise ValueError('unsupported retained op ' + op)
        elif o.effect:
            raise ValueError('empty effect')
        if len(o.successors) != 1:
            raise ValueError('bad linear continuation')
        if o.successors[0] != nxt: jump(0xa7, o.successors[0])
    if not out or len(out) >= 32768:
        raise ValueError('bounded fixture code')
    for at, target in fixups:
        dest = labels[target]
        if dest >= len(out): raise ValueError('branch past code')
        out[at+1:at+3] = struct.pack('>h', dest-at)
    if not {pc for pc,o in residual.items() if o.effect} <= {pc for _, pc in pc_map}:
        raise ValueError('missing effect PC')
    return bytes(out), max_local, pc_map


def replace_fixture_code(data, code, max_locals, name='k1', desc='(LClass_hvi;)V', max_stack=2):
    """Replace Code in a *temporary fixture* (classfile <=49, no handlers).

    Keep all CP entries and other methods byte-identical. No StackMapTable
    synthesis: legacy verifier format only. Never write to the input archive.
    """
    u2=lambda p:struct.unpack_from('>H',data,p)[0]
    u4=lambda p:struct.unpack_from('>I',data,p)[0]
    if data[:4]!=b'\xca\xfe\xba\xbe' or not 45<=u2(6)<=49:
        raise ValueError('unsupported fixture class version')
    p=10; i=1; cp={}
    while i<u2(8):
        tag=data[p];p+=1
        if tag==1:
            n=u2(p);p+=2;cp[i]=data[p:p+n].decode('utf8',errors='replace');p+=n
        elif tag in (3,4,9,10,11,12):p+=4
        elif tag in (5,6):p+=8;i+=1
        elif tag in (7,8):p+=2
        else:raise ValueError('unsupported fixture CP')
        i+=1
    p+=6;p+=2+2*u2(p)
    matches=[]
    for methods in (False,True):
        total=u2(p);p+=2
        for _ in range(total):
            flags=u2(p); key=(cp[u2(p+2)],cp[u2(p+4)]); count=u2(p+6);p+=8
            for _ in range(count):
                attr=cp[u2(p)];size=u4(p+2);end=p+6+size
                if methods and key==(name,desc) and attr=='Code':
                    if flags&0x520 or not flags&8 or u2(p+14+u4(p+10)):
                        raise ValueError('unsupported fixture method')
                    body=struct.pack('>HHI',max_stack,max_locals,len(code))+code+b'\0\0\0\0'
                    matches.append((p,end,data[p:p+2]+struct.pack('>I',len(body))+body))
                p=end
    if len(matches)!=1: raise ValueError('fixture method identity')
    a,b,replacement=matches[0]
    return data[:a]+replacement+data[b:]
