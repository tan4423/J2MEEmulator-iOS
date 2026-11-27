"""Differential of the real deferred callback loop and collector-local index."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

JVM = Path(__file__).resolve().parents[2] / 'J2MEEmulator/minijvm/jvm'
PRELUDE = r'''
#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#define JARBOX_GC_DEFERRED_INDEX_EXPERIMENT 1
#define GCFLAG_FINALIZED_GET(x) ((x)&0x40)
#define GCFLAG_FINALIZED_SET(x) ((x)|=0x40)
#define GCFLAG_WEAKREFERENCE_GET(x) ((x)&0x20)
enum { MEM_TYPE_INS=1, MEM_TYPE_ARR, MEM_TYPE_CLASS };
enum { CLASS_STATUS_CLINITED=3 };
enum { GARBAGE_THREAD_NORMAL, GARBAGE_THREAD_PAUSE, GARBAGE_THREAD_STOP, GARBAGE_THREAD_DEAD };
typedef struct { int status, finalizeMethod; } JClass;
typedef struct MemoryBlock {
    struct MemoryBlock *next,*tmp_next;
    JClass *clazz;
    unsigned type,garbage_mark,gcflag,id;
} MemoryBlock;
static int fail_alloc;
static size_t live_alloc;
static void *jvm_malloc(size_t n) {
    if (fail_alloc) return NULL;
    void *p=malloc(n); if (p) ++live_alloc; return p;
}
static void jvm_free(void *p) { assert(p && live_alloc); --live_alloc; free(p); }
#include "jarbox_gc_deferred_index.h"
typedef struct Instance { MemoryBlock mb; struct Instance *target; } Instance;
typedef struct { struct { int reference_target; } shortcut; } MiniJVM;
typedef struct GcCollector {
    MiniJVM *jvm; MemoryBlock *header; struct GcCollector *runtime;
    unsigned mark_cnt; int status,stop_after;
    JarBoxGCDeferredIndex deferred_index;
    unsigned log[1024],nlog;
} GcCollector;
static int gc_thread_status(GcCollector *c) { return c->status; }
static void event(GcCollector *c,MemoryBlock *m,unsigned kind) {
    assert(c->nlog < 1024); c->log[c->nlog++]=m->id*4+kind;
    if (c->stop_after && c->nlog==(unsigned)c->stop_after) c->status=GARBAGE_THREAD_STOP;
}
static void instance_finalize(Instance *i,GcCollector *c) { event(c,&i->mb,1); }
static void instance_of_reference_enqueue(Instance *i,GcCollector *c) { event(c,&i->mb,2); }
static Instance **getInstanceFieldPtr(Instance *i,int f) { (void)f;return &i->target; }
static Instance *getFieldRefer(Instance **p) { return *p; }
static void _gc_mark_object(GcCollector *c,MemoryBlock *m,unsigned mark) {
    event(c,m,3); m->garbage_mark=mark;
}
'''
MAIN = r'''
#define N 96
static uint32_t rng=123456789;
static unsigned rnd(void) { rng^=rng<<13; rng^=rng>>17; rng^=rng<<5; return rng; }
static void merge(GcCollector *c, Instance *nodes, unsigned first, unsigned end) {
    MemoryBlock *old=c->header;
    for (unsigned i=first;i<end;++i) {
        nodes[i].mb.next=c->header; c->header=&nodes[i].mb;
    }
    gc_deferred_index_add(&c->deferred_index,c->header,old);
}
static void sweep(GcCollector *c) {
    gc_deferred_index_prune(&c->deferred_index,c->mark_cnt);
    MemoryBlock **p=&c->header;
    while (*p) {
        MemoryBlock *m=*p;
        if (m->garbage_mark!=c->mark_cnt) *p=m->next;
        else p=&m->next;
    }
}
static void verify_index(GcCollector *c) {
    size_t cursor=c->deferred_index.count;
    for (MemoryBlock *m=c->header;m;m=m->next) {
        if (cursor && c->deferred_index.items[cursor-1]==m) { --cursor; continue; }
        assert(m->type!=MEM_TYPE_INS || (!GCFLAG_WEAKREFERENCE_GET(m->gcflag) &&
            m->clazz->status==CLASS_STATUS_CLINITED && !m->clazz->finalizeMethod));
    }
    assert(cursor==0);
}
int main(void) {
    unsigned cycles=0;
    for (unsigned trial=0;trial<2000;++trial) {
        MiniJVM va={0},vb={0};
        GcCollector a={.jvm=&va},b={.jvm=&vb}; a.runtime=&a;b.runtime=&b;
        gc_deferred_index_disable(&a.deferred_index);
        JClass ca[3]={{3,0},{3,1},{1,0}},cb[3]={{3,0},{3,1},{1,0}};
        Instance na[N]={0},nb[N]={0},ta={0},tb={0};
        for(unsigned i=0;i<N;++i) {
            unsigned cl=rnd()%3,typ=rnd()%3+1,flag=(rnd()%5==0)?0x20:0;
            na[i].mb=(MemoryBlock){.clazz=&ca[cl],.type=typ,.gcflag=flag,.id=i};
            nb[i].mb=(MemoryBlock){.clazz=&cb[cl],.type=typ,.gcflag=flag,.id=i};
            if(flag){na[i].target=&ta;nb[i].target=&tb;}
        }
        for(unsigned round=0;round<6;++round) {
            if(round==2) { ca[2].status=cb[2].status=3; ca[2].finalizeMethod=cb[2].finalizeMethod=1; }
            merge(&a,na,round*16,(round+1)*16);merge(&b,nb,round*16,(round+1)*16);
            verify_index(&b);
            // Simulate aborted root copy after the list merge: the index
            // must still include both the aborted and the next batch.
            if(trial%11==0 && round==1) continue;
            a.mark_cnt=b.mark_cnt=round+1;
            a.nlog=b.nlog=0;
            a.status=b.status=(trial%13==0)?GARBAGE_THREAD_PAUSE:GARBAGE_THREAD_NORMAL;
            a.stop_after=b.stop_after=(trial%7==0)?1:0;
            ta.mb.garbage_mark=tb.mb.garbage_mark=(rnd()%3)?0:a.mark_cnt;
            for(unsigned i=0;i<(round+1)*16;++i) {
                unsigned mark=(rnd()%2)?a.mark_cnt:0;
                na[i].mb.garbage_mark=nb[i].mb.garbage_mark=mark;
            }
            gc_process_deferred_objects(&a);gc_process_deferred_objects(&b);
            assert(a.status==b.status && a.nlog==b.nlog);
            assert(!memcmp(a.log,b.log,a.nlog*sizeof(*a.log)));
            for(unsigned i=0;i<(round+1)*16;++i) {
                assert(na[i].mb.garbage_mark==nb[i].mb.garbage_mark);
                assert(na[i].mb.gcflag==nb[i].mb.gcflag);
                assert(!na[i].mb.tmp_next && !nb[i].mb.tmp_next);
            }
            sweep(&a);sweep(&b);verify_index(&b);++cycles;
            MemoryBlock *x=a.header,*y=b.header;
            while(x&&y){assert(x->id==y->id);x=x->next;y=y->next;}
            assert(!x&&!y);
        }
        gc_deferred_index_disable(&b.deferred_index);
        assert(!live_alloc);
    }
    // Allocation failure after a previously published batch and cap
    // overflow both abandon the entire index, never a partial selection.
    JarBoxGCDeferredIndex index={0}; JClass cls={3,1};
    MemoryBlock *nodes=calloc(JARBOX_GC_DEFERRED_LIMIT+1,sizeof(*nodes));assert(nodes);
    for(unsigned i=0;i<=JARBOX_GC_DEFERRED_LIMIT;++i) {
        nodes[i].type=MEM_TYPE_INS;nodes[i].clazz=&cls;
        nodes[i].next=i?&nodes[i-1]:NULL;
    }
    gc_deferred_index_add(&index,&nodes[63],NULL);assert(index.count==64);
    fail_alloc=1;gc_deferred_index_add(&index,&nodes[64],&nodes[63]);
    assert(index.disabled&&!index.items&&!index.count&&!live_alloc);fail_alloc=0;
    index=(JarBoxGCDeferredIndex){0};
    gc_deferred_index_add(&index,&nodes[JARBOX_GC_DEFERRED_LIMIT],NULL);
    assert(index.disabled&&!index.items&&!index.count&&!live_alloc);
    free(nodes);
    printf("deferred index: %u exact callback/sweep model cycles PASS\n",cycles);
}
'''

class DeferredIndexTest(unittest.TestCase):
    def test_order_abort_stop_late_class_and_capacity(self):
        cc = shutil.which(os.environ.get('CC','cc'))
        if not cc:
            self.skipTest('host C compiler unavailable')
        gc = (JVM / 'garbage.c').read_text()
        start = gc.index('static void gc_process_deferred_objects(')
        end = gc.index('\n}', start) + 2
        flags = ['-std=c11','-Wall','-Wextra','-Werror','-O1']
        if os.environ.get('JARBOX_GC_DEFER_SANITIZE') == '1':
            flags += ['-fsanitize=address,undefined','-fno-omit-frame-pointer','-g']
        with tempfile.TemporaryDirectory() as d:
            src = Path(d)/'test.c';exe = Path(d)/'test'
            src.write_text(PRELUDE+gc[start:end]+MAIN)
            subprocess.run([cc,*flags,'-I',str(JVM),str(src),'-o',str(exe)],check=True,timeout=30)
            result = subprocess.run([str(exe)],capture_output=True,text=True,timeout=30)
            self.assertEqual(result.returncode,0,result.stdout+result.stderr)
            self.assertIn('11818 exact callback/sweep model cycles PASS',result.stdout)

    def test_index_lifetime_wiring(self):
        gc = (JVM/'garbage.c').read_text()
        collect = gc.split('s64 _garbage_collect(GcCollector *collector) {',1)[1]
        self.assertLess(collect.index('gc_deferred_index_add('),collect.index('_gc_copy_objs(jvm)'))
        self.assertLess(collect.index('gc_process_deferred_objects(collector);'),collect.index('gc_deferred_index_prune('))
        self.assertLess(collect.index('gc_deferred_index_prune('),collect.index('memoryblock_destroy(curmb);'))
        destroy = gc.split('void gc_destroy(MiniJVM *jvm) {',1)[1].split('\n}',1)[0]
        self.assertLess(destroy.index('gc_deferred_index_disable('),destroy.index('_garbage_clear(collector)'))
