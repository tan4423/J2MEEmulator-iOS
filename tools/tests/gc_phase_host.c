#include "jarbox_gc_phase.h"
#include <assert.h>
#include <pthread.h>
#include <stdio.h>
static JarBoxGCPhaseStats shared;
static JarBoxGCPhaseCycle cycle(void) {
    JarBoxGCPhaseCycle c={0};
    for(unsigned i=0;i<7;i++){c.cpu[i]=100+i*i;c.wall[i]=1000+10*i;}
    c.scanned=100;c.reclaimed=30;c.freed_bytes=1234;
    return c;
}
static void *worker(void *arg) {
    (void)arg;JarBoxGCPhaseCycle c=cycle();
    for(unsigned i=0;i<20000;i++)jarbox_gc_phase_publish(&shared,&c,0);
    return NULL;
}
static void validate(JarBoxGCPhaseTotals *t) {
    for(unsigned i=0;i<6;i++){assert(t->cpu[i]==t->cycles*(2*i+1));assert(t->wall[i]==t->cycles*10);}
    assert(t->scanned==100*t->cycles && t->reclaimed==30*t->cycles && t->freed_bytes==1234*t->cycles);
}
int main(void) {
    JarBoxGCPhaseStats a={0},b={0};JarBoxGCPhaseCycle c=cycle();JarBoxGCPhaseTotals t;
    for(unsigned i=0;i<100000;i++)assert(jarbox_gc_phase_publish(&a,&c,0));
    assert(jarbox_gc_phase_snapshot(&a,&t)&&t.cycles==100000);validate(&t);
    assert(jarbox_gc_phase_snapshot(&b,&t)&&!t.cycles);validate(&t);
    assert(!jarbox_gc_phase_publish(&a,&c,1)&&a.aborted==1);
    c.cpu[3]=0;assert(!jarbox_gc_phase_publish(&a,&c,0));c=cycle();
    c.wall[6]=0;assert(!jarbox_gc_phase_publish(&a,&c,0));c=cycle();
    c.reclaimed=101;assert(!jarbox_gc_phase_publish(&a,&c,0));c=cycle();
    c.cpu[0]=0;assert(!jarbox_gc_phase_publish(&a,&c,0));c=cycle();
    assert(a.invalid==4);assert(jarbox_gc_phase_try(&a));
    assert(!jarbox_gc_phase_publish(&a,&c,0)&&a.busy==1);
    assert(!jarbox_gc_phase_snapshot(&a,&t)&&!t.cycles);jarbox_gc_phase_unlock(&a);
    assert(jarbox_gc_phase_snapshot(&a,&t)&&t.cycles==100000);validate(&t);
    pthread_t workers[4];for(unsigned i=0;i<4;i++)assert(!pthread_create(&workers[i],NULL,worker,NULL));
    for(unsigned i=0;i<100000;i++)if(jarbox_gc_phase_snapshot(&shared,&t))validate(&t);
    for(unsigned i=0;i<4;i++)assert(!pthread_join(workers[i],NULL));
    assert(jarbox_gc_phase_snapshot(&shared,&t));validate(&t);assert(t.cycles>0&&t.cycles+shared.busy==80000);
    puts("PASS 100000 complete cycles, 80000 concurrent attempts, coherent snapshots, invalid/abort/busy and owner isolation");
}
