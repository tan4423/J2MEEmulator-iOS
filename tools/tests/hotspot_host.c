#include "jarbox_hotspot.h"
#include <assert.h>
#include <pthread.h>
static JarBoxHotspot shared;
static void *worker(void *p) {
    (void)p;
    for(unsigned i=0;i<20000;i++)jarbox_hot_note(&shared,"Game","loop","()V",1,i);
    return NULL;
}
int main(void) {
    uint64_t next=0;
    assert(!jarbox_hot_due(0,&next));assert(!jarbox_hot_due(1,&next));
    assert(!jarbox_hot_due(10000000,&next));assert(jarbox_hot_due(10000001,&next));
    assert(jarbox_hot_due(1000000000,&next));assert(!jarbox_hot_due(1000000001,&next));
    JarBoxHotspot a={0},b={0};char out[JARBOX_HOT_TEXT];uint64_t count;
    for(unsigned i=0;i<10000;i++) {
        char name[32];snprintf(name,sizeof(name),"noise%u",i);
        jarbox_hot_note(&a,"Game","paint","([Ljava/lang/String;)V",1,i);
        jarbox_hot_note(&a,"Game",name,"()V",2,i);
    }
    assert(jarbox_hot_report(&a,&count,out)&&count==20000);
    assert(strstr(out,"10000:0:9999:1:Game~paint~(%5BLjava/lang/String%3B)V"));
    uint64_t sum=0;for(unsigned i=0;i<JARBOX_HOT_ROWS;i++){sum+=a.row[i].count;assert(a.row[i].error<=a.row[i].count);}assert(sum==count);
    assert(jarbox_hot_report(&b,&count,out)&&count==0&&!out[0]);
    char longname[200];memset(longname,'x',sizeof(longname)-1);longname[sizeof(longname)-1]=0;
    jarbox_hot_note(&a,longname,"paint","()V",1,0);assert(a.invalid==1);
    assert(jarbox_hot_try(&a));jarbox_hot_note(&a,"Game","paint","()V",1,0);assert(a.busy==1);
    assert(!jarbox_hot_report(&a,&count,out)&&!out[0]);jarbox_hot_unlock(&a);
    pthread_t threads[8];for(unsigned i=0;i<8;i++)assert(!pthread_create(&threads[i],NULL,worker,NULL));
    for(unsigned i=0;i<8;i++)assert(!pthread_join(threads[i],NULL));
    assert(jarbox_hot_report(&shared,&count,out));assert(count+shared.busy==160000);
    assert(count>0&&strstr(out,"Game~loop~()V"));
    puts("PASS hotspot bounds, escaping, heavy hitters, clock gate, 160000 concurrent attempts, owner isolation");
}
