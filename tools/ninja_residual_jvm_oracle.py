#!/usr/bin/env python3
"""Independent OpenJDK wrapper oracle with instrumented LCDUI stubs, NOT MiniJVM."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile
from ninja_residual_verify import compile_ir, types, I
from ninja_paint_slice import parse, label
from ninja_wrapper_residual import SAFE_DRAWS


def java_types(desc):
    return ['int' if t==I else 'Image' for t in types(desc)]


def emit_method(index,key,nodes):
    owner=key[0];argtypes=[owner]+java_types(key[2]);args=[f'{t} a{i}' for i,t in enumerate(argtypes)]
    expressions={-i-1:f'a{i}' for i in range(len(args))};lines=[f' static void residual{index}({", ".join(args)}) {{']
    for n,(_,op,t,parents,v) in enumerate(nodes):
        p=[expressions[x] for x in parents]
        if op in ('load','store'): expressions[n]=p[0]
        elif op=='imul': expressions[n]=f'({p[0]} * {p[1]})'
        elif op=='const': expressions[n]=str(v)
        elif op in ('getstatic','getfield'):
            cl,field,_=v;expr=f'readInt({cl}.class, "{field}")' if op=='getstatic' else f'readGraphics({cl}.class, "{field}", {p[0]})'
            lines.append(f'  {"int" if t==I else "Graphics"} v{n} = {expr};');expressions[n]=f'v{n}'
        elif op=='call':
            lines.append(f'  if (!Graphics.canSkip({p[0]})) {p[0]}.{v[1]}({", ".join(p[1:])});')
        elif op!='return': raise ValueError(op)
    return '\n'.join(lines+[' }'])


def run_jar(jar,entry,trials):
    if hashlib.sha256(jar.read_bytes()).hexdigest()!=entry['sha256']: raise ValueError('SHA mismatch')
    owners=sorted({x['method'].split('.',1)[0] for x in entry['plans']})
    if len(owners)!=1: raise ValueError('one wrapper class expected')
    owner=owners[0]
    raw=subprocess.check_output(['javap','-classpath',str(jar),'-p','-s','-c',owner],text=True,timeout=60)
    _,methods=parse(raw);wanted={p['method'] for p in entry['plans']};methods=[(k,m) for k,m in sorted(methods.items()) if label(k) in wanted]
    if len(methods)!=len(wanted): raise ValueError('missing method')
    generated=[];cases=[];fields=set()
    for i,(k,m) in enumerate(methods):
        nodes,_=compile_ir(k,m);generated.append(emit_method(i,k,nodes))
        fields.update(v[1] for _,op,_,_,v in nodes if op=='getstatic')
        ts=java_types(k[2]);params=[f'{t} p{j}' for j,t in enumerate(ts)]
        vals=[f'r.nextInt()' if t=='int' else 'new Image()' for t in ts]
        decls=' '.join(f'{p} = {v};' for p,v in zip(params,vals));args=', '.join(f'p{j}' for j in range(len(ts)))
        cases.append(f'case {i}: {{ {decls} check(() -> original.{k[1]}({args}), () -> residual{i}(copy, {args}), scenario); break; }}')
    if len(fields)!=1: raise ValueError('one scale field expected')
    scale=fields.pop()
    graphics='''package javax.microedition.lcdui;
import java.util.Arrays;
public class Graphics {
 public static String event; public final int kind;
 public Graphics(int k) {kind=k;}
 public static boolean canSkip(Graphics g) { return g != null && g.getClass()==Graphics.class && g.kind==0; }
 public void note(String name,Object... args) { if(!canSkip(this)) event=name+Arrays.toString(args); }
'''
    for name,desc in SAFE_DRAWS.items():
        ts=java_types(desc);args=', '.join(f'{t} a{i}' for i,t in enumerate(ts));vals=', '.join(f'a{i}' for i in range(len(ts)))
        graphics+=f' public void {name}({args}) {{ note("{name}", {vals}); }}\n'
    graphics+='}\n'
    harness=f'''import javax.microedition.lcdui.*;
import java.util.*;
public class Oracle {{
{chr(10).join(generated)}
 static int readInt(Class<?> c,String name) {{try {{return c.getField(name).getInt(null);}} catch(ReflectiveOperationException e) {{throw new AssertionError(e);}}}}
 static Graphics readGraphics(Class<?> c,String name,Object o) {{try {{return (Graphics)c.getField(name).get(o);}} catch(ReflectiveOperationException e) {{throw new AssertionError(e);}}}}
 static void writeInt(Class<?> c,String name,int v) {{try {{c.getField(name).setInt(null,v);}} catch(ReflectiveOperationException e) {{throw new AssertionError(e);}}}}
 interface Call {{void run();}}
 static String trace(Call c) {{ Graphics.event=null; try {{c.run();return "return:"+Graphics.event;}} catch(NullPointerException t) {{return t.getClass().getName();}} }}
 static void check(Call a,Call b,int scenario) {{String x=trace(a),y=trace(b);if(!x.equals(y) || (scenario==4 ? !x.equals("java.lang.NullPointerException") : scenario==0 ? !x.equals("return:null") : !x.startsWith("return:draw") && !x.startsWith("return:fill"))) throw new AssertionError(scenario+":"+x+" != "+y);}}
 public static void main(String[] args) {{Random r=new Random(20261126L); int count=0;
 for(int i=0;i<{trials};i++) {{int scenario=i%5; Graphics g=scenario==4?null:scenario==3?new Graphics(0){{}}:new Graphics(scenario);
 writeInt({owner}.class,"{scale}",r.nextInt()); {owner} original=new {owner}(g),copy=new {owner}(g);
 for(int j=0;j<{len(methods)};j++) {{switch(j) {{ {chr(10).join(cases)} }} count++;}}
 }} System.out.println(count); }}
}}'''
    with tempfile.TemporaryDirectory() as td:
        root=Path(td);pkg=root/'javax/microedition/lcdui';pkg.mkdir(parents=True)
        (pkg/'Graphics.java').write_text(graphics);(pkg/'Image.java').write_text('package javax.microedition.lcdui; public class Image {}\n');(root/'Oracle.java').write_text(harness)
        subprocess.run(['javac','-cp',str(jar),'-d',str(root),str(pkg/'Graphics.java'),str(pkg/'Image.java'),str(root/'Oracle.java')],check=True,text=True,timeout=60)
        result=subprocess.check_output(['java','-Xint','-Xverify:all','-cp',str(root)+':'+str(jar),'Oracle'],text=True,timeout=60)
    return {'jar':jar.name,'wrappers':len(methods),'cases':int(result.strip()),'engine':'OpenJDK interpreter, original wrapper classfiles, LCDUI test doubles','runtime_authorized':False}


def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('jars',nargs='+',type=Path);p.add_argument('--plans',required=True,type=Path);p.add_argument('--output',required=True,type=Path);p.add_argument('--trials',type=int,default=1000);a=p.parse_args()
    if not 1<=a.trials<=100000:p.error('trials outside limit')
    inv={x['sha256']:x for x in json.loads(a.plans.read_text())['jars']}
    out=[run_jar(x,inv[hashlib.sha256(x.read_bytes()).hexdigest()],a.trials) for x in a.jars]
    a.output.write_text(json.dumps(out,indent=2)+'\n')
if __name__=='__main__':main()
