#!/usr/bin/env python3
"""Read-only Ninja paint effect inventory and local slice candidate census.
Requires javap. No rewriting, execution or authorization of elision.
"""
import argparse
from collections import Counter, defaultdict, deque
import hashlib
import json
from pathlib import Path
import re
import subprocess
import zipfile

G = 'javax/microedition/lcdui/Graphics'
DESC = '(Ljavax/microedition/lcdui/Graphics;)V'
DRAWS = set('drawRegion drawImage drawString drawChar drawSubstring drawChars drawLine fillRect drawRect fillArc drawArc fillRoundRect drawRoundRect fillTriangle drawRGB fillPolygon drawPolygon'.split())
QUERIES = set('getColor getRedComponent getGreenComponent getBlueComponent getGrayScale getStrokeStyle getFont getClipX getClipY getClipWidth getClipHeight getTranslateX getTranslateY getDisplayColor getCanvasWidth getCanvasHeight getWidth getHeight stringWidth substringWidth charWidth charsWidth getBaselinePosition getSize getFace getStyle isBold isItalic isPlain isUnderlined isMutable'.split())
MEM = re.compile(r'// (?:InterfaceMethod|Method|Field) (\S+)')
INS = re.compile(r'^\s+(\d+):\s+([a-z][a-z0-9_]*)\s*(.*)$')

def parse(text):
    classes, methods = {}, {}
    owner = decl = key = None
    for line in text.splitlines():
        if line and not line[0].isspace() and line.endswith(' {'):
            m = re.search(r'\b(?:class|interface) ([\w.$]+)(.*) \{$', line)
            if not m:
                raise ValueError('unparsed class header: '+line)
            owner = m[1].replace('.', '/')
            parents = re.sub(r'\b(?:extends|implements)\b', '', m[2]).replace(',', ' ').split()
            classes[owner] = [p.replace('.', '/') for p in parents]
            decl = key = None
        elif line.startswith('  ') and not line.startswith('   ') and line.endswith(';'):
            decl, key = line.strip(), None
        elif line.strip().startswith('descriptor: ') and decl:
            desc = line.strip().split(' ', 1)[1]
            if desc.startswith('('):
                name = '<clinit>' if decl == 'static {};' else decl.split('(')[0].split()[-1]
                if name.replace('.', '/') == owner and len([x for x in decl.split('(')[0].split() if x not in ('public','private','protected')]) == 1:
                    name = '<init>'
                key = (owner, name, desc)
                if key in methods:
                    raise ValueError('duplicate method: '+str(key))
                methods[key] = {'decl': decl, 'ins': [], 'handlers': False, 'switch_targets': set()}
        elif key and line.strip() == 'Exception table:':
            methods[key]['handlers'] = True
        elif key and (m := INS.match(line)):
            methods[key]['ins'].append((int(m[1]), m[2], m[3]))
        elif key and (m := re.match(r'^\s+(?:-?\d+|default):\s+(\d+)\s*$', line)):
            methods[key]['switch_targets'].add(int(m[1]))
    return classes, methods

def member(owner, operand):
    m = MEM.search(operand)
    if not m:
        return None
    name, desc = m[1].rsplit(':', 1)
    cl, name = name.rsplit('.', 1) if '.' in name else (owner, name)
    return cl, name.strip('"'), desc

def ancestors(c, classes):
    seen, todo = set(), [c]
    while todo:
        x = todo.pop()
        if x not in seen:
            seen.add(x); todo.extend(classes.get(x, []))
    return seen

def label(k):
    return k[0]+'.'+k[1]+':'+k[2]

def kind(k):
    cl, name, desc = k
    if cl == G and name in DRAWS and desc.endswith(')V'):
        return 'possible_screen_sink'  # receiver may be Image Graphics; not proven
    if cl in (G, 'javax/microedition/lcdui/Font', 'javax/microedition/lcdui/Image') and name in QUERIES:
        return 'query_keep'
    return 'external_effect_or_unknown_keep'

def argc(desc):
    # Draw arguments are all category-1; reject long/double rather than guess.
    args = re.findall(r'\[*(?:L[^;]+;|[BCDFIJSZ])', desc[1:desc.index(')')])
    return len(args) if not any(a in ('D','J') for a in args) else None

def pure_stack(op, operand):
    if re.fullmatch(r'(?:[ia]load(?:_[0-3])?|iconst_(?:m1|[0-5])|bipush|sipush|aconst_null)', op):
        return 0
    if op in ('ldc','ldc_w') and '// int ' in operand:
        return 0
    if op in 'iadd isub imul iand ior ixor ishl ishr iushr'.split():
        return 2
    if op in ('ineg','i2b','i2c','i2s'):
        return 1
    return None  # includes field/array reads, calls, allocation, division, sync

def suffix(m, idx, ref):
    # Contiguous, local argument-only expression ending at draw; receiver
    # stays on stack. Branch targets/exception handlers are never crossed.
    # This is a conditional candidate, NOT a valid bytecode rewrite.
    if m['handlers']:
        return []
    need = argc(ref[2])
    if not need:
        return []
    targets = set(m['switch_targets'])
    for pc, op, arg in m['ins']:
        if op.startswith('if') or op in ('goto','goto_w','jsr','jsr_w'):
            targets.add(int(arg.split()[0]))
    indices = []
    for j in range(idx-1, -1, -1):
        pc, op, arg = m['ins'][j]
        if m['ins'][j+1][0] in targets:
            return []
        pop = pure_stack(op,arg)
        if pop is None:
            return []
        need += pop-1
        indices.append(j)
        if need == 0:
            return indices
    return []

def analyze(path):
    with zipfile.ZipFile(path) as z:
        names = [x.filename for x in z.infolist() if x.filename.endswith('.class')]
        if not names or len(names)>2000 or len(set(names))!=len(names):
            raise ValueError('unsupported archive class inventory')
        if sum(z.getinfo(n).file_size for n in names)>64*1024*1024:
            raise ValueError('class bytes exceed limit')
    result = subprocess.run(['javap','-classpath',str(path),'-p','-s','-c',*[n[:-6].replace('/','.') for n in names]],check=True,capture_output=True,text=True,timeout=90)
    classes, methods = parse(result.stdout)
    if len(classes)!=len(names):
        raise ValueError('incomplete javap inventory')
    supers = {c:ancestors(c,classes) for c in classes}
    roots = sorted(k for k in methods if k[1:] == ('paint',DESC) and 'javax/microedition/lcdui/Canvas' in supers[k[0]])
    if not roots:
        raise ValueError('no Canvas paint root')
    # Class-hierarchy overapproximation, no receiver points-to proof.
    by_sig = defaultdict(list)
    for k in methods:
        if methods[k]['ins']:
            by_sig[k[1:]].append(k)
    edges, extern, callsites = defaultdict(set), defaultdict(list), defaultdict(list)
    reads, writes = defaultdict(list), defaultdict(list)
    for k,m in methods.items():
        for idx,(pc,op,arg) in enumerate(m['ins']):
            if op in ('getfield','getstatic','putfield','putstatic'):
                ref = member(k[0],arg)
                if ref:
                    (reads if op.startswith('get') else writes)[ref].append((k,pc,op))
            if not op.startswith('invoke'):
                continue
            ref = member(k[0],arg)
            candidates = []
            if ref:
                if op in ('invokevirtual','invokeinterface'):
                    candidates = [x for x in by_sig[ref[1:]] if ref[0] in supers.get(x[0],set()) or x[0] in supers.get(ref[0],set())]
                elif op in ('invokestatic','invokespecial'):
                    if ref in methods and methods[ref]['ins']:
                        candidates = [ref]
                    elif ref[1] != '<init>':
                        candidates = [x for x in by_sig[ref[1:]] if x[0] in supers.get(ref[0],{ref[0]})]
            edges[k].update(candidates)
            callsites[k].append((idx,ref,candidates))
            if not candidates or op=='invokeinterface':
                extern[k].append((idx,ref))
    reachable=set(); todo=deque(roots)
    while todo:
        k=todo.popleft()
        if k not in reachable:
            reachable.add(k); todo.extend(edges[k]-reachable)
    ops=Counter(); kinds=Counter(); ext=Counter(); candidates=[]
    for k in sorted(reachable):
        m=methods[k]; ops.update(op for _,op,_ in m['ins'])
        for idx,ref in extern[k]:
            category=kind(ref) if ref else 'external_effect_or_unknown_keep'
            kinds[category]+=1; ext[label(ref) if ref else '<unresolved>']+=1
            if category=='possible_screen_sink':
                chain=suffix(m,idx,ref)
                candidates.append({'method':label(k),'pc':m['ins'][idx][0],'target':label(ref),'argument_pcs':sorted(m['ins'][j][0] for j in chain)})
    # Wrapper summaries are structural candidates only. Field reads may
    # throw or trigger class initialization; the eventual specialization
    # must preserve those effects and test the actual Graphics receiver.
    wrapper_keys=set()
    for k in reachable:
        m=methods[k]
        if m['handlers'] or ' synchronized ' in ' '+m['decl']+' ' or not k[2].endswith(')V'):
            continue
        if len(callsites[k])!=1:
            continue
        idx,ref,targets=callsites[k][0]
        if not ref or targets or kind(ref)!='possible_screen_sink':
            continue
        if all(j==idx or pure_stack(op,arg) is not None or op in ('getfield','getstatic','return') or re.fullmatch(r'istore(?:_[0-3])?',op) for j,(_,op,arg) in enumerate(m['ins'])):
            wrapper_keys.add(k)
    wrapper_sites=[]
    for k in sorted(reachable):
        m=methods[k]
        for idx,ref,targets in callsites[k]:
            if len(targets)==1 and targets[0] in wrapper_keys and ref:
                chain=suffix(m,idx,ref)
                wrapper_sites.append({'method':label(k),'pc':m['ins'][idx][0],'target':label(targets[0]),'argument_pcs':sorted(m['ins'][j][0] for j in chain)})
    selected={f for f,sites in writes.items() if any(k in reachable for k,_,_ in sites)}
    def sites(items):
        return [{'method':label(k),'pc':pc,'op':op,'in_paint_graph':k in reachable} for k,pc,op in sorted(items)]
    fields=[{'field':label(f),'writes':sites(writes[f]),'reads':sites(reads[f])} for f in sorted(selected)]
    total=sum(ops.values()); operand_count=sum(len(x['argument_pcs']) for x in candidates)
    return {'jar':path.name,'sha256':hashlib.sha256(path.read_bytes()).hexdigest(),'class_count':len(classes),'root_methods':[label(k) for k in roots], 'paint_graph_method_count':len(reachable),'paint_graph_instruction_count':total,'opcode_counts':dict(ops),'external_call_categories':dict(kinds),'external_call_targets':dict(ext),'fields_written_from_graph':fields,'array_store_sites':sum(ops[x] for x in 'iastore lastore fastore dastore aastore bastore castore sastore'.split()),'monitor_sites':ops['monitorenter']+ops['monitorexit'],'synchronized_methods':sum(' synchronized ' in ' '+methods[k]['decl']+' ' for k in reachable),'exception_table_methods':sum(methods[k]['handlers'] for k in reachable),'conditional_sink_sites':candidates,'conditional_local_arg_instructions':operand_count,'conditional_sink_plus_arg_pct':round(100*(len(candidates)+operand_count)/total,3),'draw_wrapper_candidates':[label(k) for k in sorted(wrapper_keys)],'wrapper_call_sites':wrapper_sites,'conditional_wrapper_arg_instructions':sum(len(x['argument_pcs']) for x in wrapper_sites),'proven_removable_instructions':0,'limitations':['Static potential reachability only; inherited implementations and library callbacks may be missed. No implicit class-init edges, reflection, full alias/exception/CFG analysis, or runtime receiver proof.','Field references use symbolic owners; inherited aliases may be split. Outside-graph readers are not proof of update-loop execution.','Conditional counts assume screen receiver and preserved exception/stack semantics; not an executable slice or CPU estimate. No JAR or VM execution.']}

def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('jars',nargs='+',type=Path);p.add_argument('--output',type=Path,required=True);a=p.parse_args()
    a.output.write_text(json.dumps({'format':'jarbox-ninja-paint-static-v1','jars':[analyze(x) for x in a.jars]},indent=2,ensure_ascii=False)+'\n')
if __name__=='__main__':main()
