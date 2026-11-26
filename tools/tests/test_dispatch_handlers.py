"""Compile the real fast virtual/interface handler bodies in both cache modes.

VM layouts, loader resolution, callee execution and exception destinations are
modeled. This is not a full MiniJVM, class unloading, or iOS integration test.
"""
from pathlib import Path
import os
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
JVM = ROOT / "J2MEEmulator/minijvm/jvm"
PRE = r"""
#include <assert.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include "jarbox_dispatch_cache.h"
#define _JVM_DEBUG_PROFILE 0
#define TREO_VM_HANDLER(op)
typedef uint16_t u16;
enum { MEM_TYPE_INS=1, MEM_TYPE_ARR=2 };
enum { op_invokevirtual_fast=1,op_invokeinterface_fast,op_invokevirtual,op_invokeinterface };
enum { OK, BOUNCE, NULL_ERR, NO_METHOD, THROWN };
typedef struct JClass JClass;
typedef struct MethodInfo MethodInfo;
typedef struct ConstantMethodRef ConstantMethodRef;
struct JClass { uint64_t dispatch_id; void *jloader; ConstantMethodRef *ref; };
struct MethodInfo { JClass *_this_class; int result, throws; };
typedef struct { struct { JClass *clazz; int type; } mb; MethodInfo *resolved; } Instance;
typedef struct { int lock_cloader; } MiniJVM;
typedef struct { void *rvalue; } StackEntry;
typedef struct { StackEntry *sp; } RuntimeStack;
typedef struct { unsigned char *pc; RuntimeStack *stack; MiniJVM *jvm; } Runtime;
typedef struct { JClass *keys[8]; MethodInfo *values[8]; unsigned count; } Pairlist;
struct ConstantMethodRef { int para_slots; const char *name,*descriptor; Pairlist *virtual_methods; JarBoxDispatchCache dispatch_cache; };
static unsigned lock_acquisitions;
static void spin_lock(int *l) { assert(!*l); *l=1; ++lock_acquisitions; }
static void spin_unlock(int *l) { assert(*l); *l=0; }
#if !JARBOX_VM_INLINE_DISPATCH
static Pairlist *pairlist_create(int n) { (void)n; return calloc(1,sizeof(Pairlist)); }
static MethodInfo *pairlist_get(Pairlist *p,JClass *c) { if(p)for(unsigned i=0;i<p->count;i++)if(p->keys[i]==c)return p->values[i]; return NULL; }
static int pairlist_put(Pairlist *p,JClass *c,MethodInfo *m) { if(!p)return -1; assert(p->count<8); p->keys[p->count]=c;p->values[p->count++]=m;return 0; }
#endif
static int calls,resolves;
static StackEntry *base;
static Instance *expected_receiver;
static MethodInfo *last_target;
static int value;
static ConstantMethodRef *class_get_constant_method_ref(JClass *c,u16 index) { assert(index==7);return c->ref; }
#if JARBOX_VM_INLINE_DISPATCH
static MethodInfo *find_instance_methodInfo_by_name(Instance *i,const char *name,const char *desc,Runtime *r) {
    assert(i==expected_receiver && !strcmp(name,"m") && !strcmp(desc,"(I)I"));
    assert(r->stack->sp==base+3 && base[1].rvalue==i);
    ++resolves;return i->resolved;
}
static const char *utf8_cstr(const char *s) { return s; }
#endif
static int execute_method_impl(MethodInfo *m,Runtime *r) {
    assert(m && r->stack->sp==base+3 && base[1].rvalue==expected_receiver);
    ++calls;last_target=m;value=m->result;
    r->stack->sp=base+(m->throws?1:2);
    return m->throws;
}
"""
OPEN = r"""
static int dispatch(Runtime *runtime,JClass *clazz) {
    RuntimeStack *stack=runtime->stack;
    StackEntry *sp=stack->sp;
    MiniJVM *jvm=runtime->jvm;
    ConstantMethodRef *cmr;
    Instance *ins;
    MethodInfo *m;
    int ret;
#if JARBOX_VM_INLINE_DISPATCH
    const char *err_msg=NULL;
#endif
    unsigned char *start=runtime->pc;
    switch(*start) {
"""
CLOSE = r"""
    default: abort();
    }
    assert(sp==stack->sp);
    return runtime->pc==start?BOUNCE:OK;
label_null_throw:
    assert(sp==stack->sp);return NULL_ERR;
#if JARBOX_VM_INLINE_DISPATCH
label_nosuchmethod_throw:
    assert(err_msg && !strcmp(err_msg,"m") && sp==stack->sp);return NO_METHOD;
#endif
label_exception_handle:
    assert(sp==stack->sp);return THROWN;
}
"""
MAIN = r"""
static void verify(MiniJVM *vm,ConstantMethodRef *ref,Instance *ins,int op,int outcome,int resolved,MethodInfo *target) {
    JClass caller={.ref=ref};
    // Keep the original u16 operand load aligned and native-endian.
    u16 code[5]={0,7,0,0,0};
    unsigned char *pc=(unsigned char*)code+1;
    *pc=(unsigned char)op;
    StackEntry entries[4]={{ref},{ins},{vm},{NULL}};
    RuntimeStack stack={entries+3};
    Runtime r={pc,&stack,vm};
    calls=resolves=value=0;last_target=NULL;base=entries;expected_receiver=ins;
    assert(dispatch(&r,&caller)==outcome);
    assert(!vm->lock_cloader && entries[0].rvalue==ref);
    assert(resolves==resolved && calls==(target!=NULL) && last_target==target);
    if(target)assert(value==target->result);
    assert(r.pc==pc+(outcome==OK?(op==op_invokevirtual_fast?3:5):0));
    assert(stack.sp==entries+(outcome==OK?2:outcome==THROWN?1:3));
    assert(*pc==(outcome==BOUNCE?(op==op_invokevirtual_fast?op_invokevirtual:op_invokeinterface):op));
    base=NULL; expected_receiver=NULL; last_target=NULL;
}
int main(void) {
    for(int round=0;round<1000;round++)for(int op=op_invokevirtual_fast;op<=op_invokeinterface_fast;op++) {
        MiniJVM a={0},b={0};int loader_a,loader_b;
        ConstantMethodRef ra={.para_slots=1,.name="m",.descriptor="(I)I"},rb=ra,empty=ra;
        JClass ca={.dispatch_id=1,.jloader=&loader_a},cb={.dispatch_id=2,.jloader=&loader_a},cc={.dispatch_id=3,.jloader=&loader_a};
        JClass cd={.dispatch_id=1,.jloader=&loader_b};
        MethodInfo ma={&ca,11,0},mb={&cb,22,1},mc={&cc,33,0},md={&cd,44,0};
        Instance ia={{&ca,MEM_TYPE_INS},&ma},ib={{&cb,MEM_TYPE_INS},&mb},ic={{&cc,MEM_TYPE_INS},&mc},id={{&cd,MEM_TYPE_INS},&md};
        assert(jarbox_virtual_publish(&a,&ra,&ia,&ma));
        assert(jarbox_virtual_publish(&b,&rb,&id,&md));
        verify(&a,&ra,&ia,op,OK,0,&ma);
        verify(&b,&rb,&id,op,OK,0,&md);
        verify(&a,&ra,NULL,op,NULL_ERR,0,NULL);
#if JARBOX_VM_INLINE_DISPATCH
        verify(&a,&ra,&ib,op,THROWN,1,&mb); // miss: throw at original PC
        verify(&a,&ra,&ib,op,THROWN,0,&mb); // cached throw
        unsigned before=lock_acquisitions;
        verify(&a,&ra,&ic,op,OK,1,&mc); // full: execute directly, no rewrite
        verify(&a,&ra,&ic,op,OK,1,&mc);
        assert(lock_acquisitions==before); // full cache never takes loader lock
        assert(!jarbox_virtual_lookup(&a,&ra,&ic));
        assert(jarbox_virtual_lookup(&a,&ra,&ia)==&ma);
        ic.mb.type=MEM_TYPE_ARR;
        verify(&a,&empty,&ic,op,OK,1,&mc);
        assert(!jarbox_virtual_lookup(&a,&empty,&ic));
        ic.mb.type=MEM_TYPE_INS;ic.resolved=&md;
        verify(&a,&empty,&ic,op,OK,1,&md); // unrelated loader: no publish
        assert(!jarbox_virtual_lookup(&a,&empty,&ic));
        ic.resolved=NULL;verify(&a,&empty,&ic,op,NO_METHOD,1,NULL);
        ic.resolved=&mc;cc.dispatch_id=0;
        verify(&a,&empty,&ic,op,OK,1,&mc); // saturated identity: no publish
        assert(!jarbox_virtual_lookup(&a,&empty,&ic));
#else
        verify(&a,&ra,&ib,op,BOUNCE,0,NULL);
        assert(jarbox_virtual_publish(&a,&ra,&ib,&mb));
        verify(&a,&ra,&ib,op,THROWN,0,&mb);
        verify(&a,&ra,&ic,op,BOUNCE,0,NULL);
        verify(&a,&empty,&ic,op,BOUNCE,0,NULL);
#endif
        free(ra.virtual_methods);free(rb.virtual_methods);free(empty.virtual_methods);
    }
    printf("dispatch handlers: 2000 batches PASS (inline=%d)\n",JARBOX_VM_INLINE_DISPATCH);
}
"""


def harness(source):
    start = source.index("static inline MethodInfo *jarbox_virtual_lookup(")
    end = source.index("#include <stdatomic.h>", start)
    handlers = []
    for op in ("op_invokevirtual_fast", "op_invokeinterface_fast"):
        start_case = source.index("case " + op + ": TREO_VM_HANDLER(" + op + ") {")
        end_case = source.index("case op_", start_case + 5)
        handlers.append(source[start_case:end_case])
    return PRE + source[start:end] + OPEN + "\n".join(handlers) + CLOSE + MAIN


class DispatchHandlerTest(unittest.TestCase):
    def test_fast_handlers_both_cache_modes(self):
        cc = shutil.which(os.environ.get("CC", "cc"))
        if not cc:
            self.skipTest("host compiler unavailable")
        code = harness((JVM / "interpreter.c").read_text())
        flags = ["-std=c11", "-O2", "-Wall", "-Wextra", "-Werror"]
        if os.environ.get("JARBOX_DISPATCH_SANITIZE") == "1":
            flags += ["-g", "-O1", "-fsanitize=address,undefined", "-fno-omit-frame-pointer"]
        with tempfile.TemporaryDirectory() as td:
            p = Path(td)
            (p / "test.c").write_text(code)
            for mode in (0, 1):
                with self.subTest(inline=mode):
                    exe = p / ("test-" + str(mode))
                    subprocess.run([cc, *flags, "-DJARBOX_VM_INLINE_DISPATCH=" + str(mode),
                                    "-I", str(JVM), str(p / "test.c"), "-o", str(exe)],
                                   check=True, timeout=30)
                    run = subprocess.run([str(exe)], capture_output=True, text=True, timeout=20)
                    self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
                    self.assertIn("2000 batches PASS", run.stdout)


if __name__ == "__main__":
    unittest.main()
