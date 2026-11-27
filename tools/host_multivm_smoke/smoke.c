/* Headless real MiniJVM integration. Only the job owner destroys its VM. */
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/stat.h>
#include <time.h>
#include "jvm.h"
#include "jvm_util.h"
#include "arraylist.h"
#include "garbage.h"

typedef struct { const char *rt, *api, *app, *tag, *mode; char save[512]; int port;
    MiniJVM *jvm; pthread_t th; pthread_mutex_t lock; atomic_int finished;
    int stop_requested, rc;
    uint64_t char_calls, array_calls, gc_cycles;
    uint64_t thread_cpu_ns, process_cpu_ns; } Job;

static void request_vm_stop(MiniJVM *vm) {
    vm->collector->exit_flag = 1;
    jarbox_session_begin_stop(vm->session);
    gc_request_thread_status(vm->collector, GARBAGE_THREAD_STOP);
    thread_stop_all(vm);
}
#if defined(JARBOX_HOST_INTRINSIC_TEST) && !__JVM_OS_IOS__
static uint64_t cpu_now(clockid_t clock) {
    struct timespec t;
    if (clock_gettime(clock,&t)) return 0;
    return (uint64_t)t.tv_sec*UINT64_C(1000000000)+(uint64_t)t.tv_nsec;
}
#endif
static void *job_main(void *p) {
    Job *j = p; char cp[2048], portbuf[16];
    snprintf(cp, sizeof cp, "%s:%s", j->api, j->app);
    snprintf(portbuf, sizeof portbuf, "%d", j->port);
    MiniJVM *vm = jvm_create();
    if (!vm) { j->rc = -2; goto done; }
    if (!jarbox_native_heap_register_vm(vm)) {
        jarbox_session_begin_stop(vm->session);
        (void)jarbox_session_mark_dead(vm->session);
        jarbox_session_release(vm->session);
        jvm_free(vm); j->rc = -4; goto done;
    }
    const uint64_t key = jarbox_native_heap_key_for_vm(vm);
    vm->jdwp_enable = 0; vm->max_heap_size = 64 * 1024 * 1024;
    vm->garbage_collect_period_ms = 200; vm->heap_overload_percent = 70;
    if (jvm_init(vm, (char *)j->rt, cp)) { j->rc = -3; goto cleanup; }
    pthread_mutex_lock(&j->lock);
    j->jvm = vm;
    pthread_mutex_unlock(&j->lock);
    ArrayList *args = arraylist_create(0);
    arraylist_push_back(args, (void *)j->tag); arraylist_push_back(args, (void *)j->save);
    arraylist_push_back(args, (void *)j->mode); arraylist_push_back(args, (void *)portbuf);
#if defined(JARBOX_HOST_INTRINSIC_TEST) && !__JVM_OS_IOS__
    int intrinsic=!strncmp(j->mode,"intrinsic-",10);
    unsigned mask=!strcmp(j->mode,"intrinsic-on")?3u:
                  !strcmp(j->mode,"intrinsic-array")?1u:
                  !strcmp(j->mode,"intrinsic-char")?2u:0u;
    if (intrinsic) {
        // Same mode/profile in ALL legs; mask is host-only and per owner.
        __atomic_store_n(&vm->session->treo_state.host_intrinsic_mask,mask,__ATOMIC_RELAXED);
        jarbox_treo_nso_profile_set(&vm->session->treo_state,1,0);
        jarbox_treo_mode_set(&vm->session->treo_state,1);
    }
    uint64_t p0=cpu_now(CLOCK_PROCESS_CPUTIME_ID),t0=cpu_now(CLOCK_THREAD_CPUTIME_ID);
    j->rc=call_main(vm,intrinsic?"IntrinsicMain":(!strcmp(j->mode,"residual")?"ResidualMain":"SmokeMain"),args);
    uint64_t t1=cpu_now(CLOCK_THREAD_CPUTIME_ID),p1=cpu_now(CLOCK_PROCESS_CPUTIME_ID);
    if (t0 && t1>t0) j->thread_cpu_ns=t1-t0;
    if (p0 && p1>p0) j->process_cpu_ns=p1-p0;
    j->char_calls=__atomic_load_n(&vm->session->treo_state.char_leaf_calls,__ATOMIC_RELAXED);
    j->array_calls=__atomic_load_n(&vm->session->treo_state.array_lookup_mode1_calls,__ATOMIC_RELAXED);
    j->gc_cycles=__atomic_load_n(&vm->session->treo_state.gc_worker_cycles,__ATOMIC_RELAXED);
#else
    j->rc = call_main(vm, !strcmp(j->mode,"residual")?"ResidualMain":"SmokeMain", args);
#endif
    arraylist_destroy(args);
    pthread_mutex_lock(&j->lock);
    j->jvm = NULL; // no controller may touch this heap during destruction
    pthread_mutex_unlock(&j->lock);
cleanup:
    request_vm_stop(vm);
    jvm_destroy(vm);
    jarbox_native_heap_unregister_key(key);
done:
    atomic_store_explicit(&j->finished, 1, memory_order_release);
    return NULL;
}
static int stop_job(Job *j) {
    pthread_mutex_lock(&j->lock);
    int live = j->jvm != NULL && !j->stop_requested;
    if (live) { j->stop_requested = 1; request_vm_stop(j->jvm); }
    pthread_mutex_unlock(&j->lock);
    return live;
}
static int result_ok(const Job *j) {
    char path[1024], expected[128], buf[128] = {0};
    snprintf(path, sizeof path, "%s/state.txt", j->save);
    snprintf(expected, sizeof expected, "tag=%s sum=198715", j->tag);
    FILE *f = fopen(path, "r"); if (!f) return 0;
    size_t n = fread(buf, 1, sizeof buf - 1, f); fclose(f);
    return n == strlen(expected) && !memcmp(buf, expected, n);
}
#if defined(JARBOX_HOST_INTRINSIC_TEST) && !__JVM_OS_IOS__
static int intrinsic_ok(const Job *j) {
    char path[1024],buf[128]={0};
    const char *expected="PASS 4902965299\n"; // verified OpenJDK fixture digest
    snprintf(path,sizeof path,"%s/intrinsic.txt",j->save);
    FILE *f=fopen(path,"r"); if(!f)return 0;
    size_t n=fread(buf,1,sizeof buf-1,f); fclose(f);
    return n==strlen(expected)&&!memcmp(buf,expected,n);
}
#endif
static int residual_equal(const Job *a,const Job *b) {
    char p[1024],q[1024],x[256],y[256];
    snprintf(p,sizeof p,"%s/residual.txt",a->save);
    snprintf(q,sizeof q,"%s/residual.txt",b->save);
    FILE *f=fopen(p,"r"),*g=fopen(q,"r");
    int ok=0;
    if(f && g) {
        int n=0,faults=0,changed=0;
        for(;n<2000;n++) {
            int index=-1,fault=-1;
            if(!fgets(x,sizeof x,f)||!fgets(y,sizeof y,g)||strcmp(x,y)||
               !strchr(x,'\n')||sscanf(x,"%d:%d:",&index,&fault)!=2||index!=n||
               fault<0||fault>3)break;
        }
        if(n==2000 && fgets(x,sizeof x,f)&&fgets(y,sizeof y,g)&&!strcmp(x,y)&&
           sscanf(x,"PASS 2000 %d %d",&faults,&changed)==2&&
           faults>0&&faults<=2000&&changed>0&&changed<=2000&&
           fgetc(f)==EOF&&fgetc(g)==EOF&&!ferror(f)&&!ferror(g))ok=1;
    }
    if(f)fclose(f);
    if(g)fclose(g);
    return ok;
}
static long heartbeat(const Job *j) {
    char path[1024]; snprintf(path, sizeof path, "%s/heartbeat.txt", j->save);
    FILE *f = fopen(path, "r"); if (!f) return -1;
    char line[64], *end; long n = -1;
    if (fgets(line, sizeof line, f)) {
        long value = strtol(line, &end, 10);
        if (end != line && *end == '\n' && end[1] == 0 && value >= 0) n = value;
    }
    fclose(f); return n;
}
static long wait_progress(const Job *j, long previous) {
    for (int i = 0; i < 500; ++i) {
        if (atomic_load_explicit(&j->finished, memory_order_acquire)) return -1;
        long n = heartbeat(j);
        if (result_ok(j) && n > previous) return n;
        usleep(20000);
    }
    return -1;
}
static void init_job(Job *j, char **a, const char *tag, const char *mode, int port, const char *base) {
    memset(j, 0, sizeof *j); j->rt = a[1]; j->api = a[2]; j->app = a[3];
    j->tag = tag; j->mode = mode; j->port = port;
    atomic_init(&j->finished, 0);
    if (pthread_mutex_init(&j->lock, NULL)) exit(2);
    snprintf(j->save, sizeof j->save, "%s/%s", base, tag);
    if (mkdir(j->save, 0755)) exit(2);
}
static void start_job(Job *j) { if (pthread_create(&j->th, NULL, job_main, j)) exit(2); }
static void join_job(Job *j) { if (pthread_join(j->th, NULL)) exit(2); pthread_mutex_destroy(&j->lock); }
#define REQUIRE(expr) do { if (!(expr)) { fprintf(stderr, "FAIL line %d: %s\n", __LINE__, #expr); return 1; } } while (0)
void smoke_install_crash_handler(void);
int main(int argc, char **argv) {
    smoke_install_crash_handler();
    if (argc != 5) return 2;
    const char *scenario = argv[4]; char base[] = "/tmp/jbsmoke.XXXXXX";
    if (!mkdtemp(base)) return 2;
    printf("save roots: %s\n", base);
    int bport = 20000 + (getpid() % 20000); Job a, b, a2;
#if defined(JARBOX_HOST_INTRINSIC_TEST) && !__JVM_OS_IOS__
    if (!strcmp(scenario,"intrinsic_bench")) {
        const char *modes[]={"intrinsic-off","intrinsic-array","intrinsic-char","intrinsic-on"};
        // Each leg owns a fresh VM, no other live VM, same Java fixture and
        // same tag prefix (salt). Rotate positions to reduce order bias.
        for (unsigned round=0;round<4;round++) {
            for (unsigned pos=0;pos<4;pos++) {
                unsigned mask=(round+pos)%4;
                char tag[32]; snprintf(tag,sizeof tag,"A%u_%u",round,pos);
                Job leg;
                init_job(&leg,argv,tag,modes[mask],bport,base);
                start_job(&leg); join_job(&leg);
                REQUIRE(!leg.rc && intrinsic_ok(&leg) && leg.gc_cycles>0);
                REQUIRE(leg.thread_cpu_ns>0 && leg.process_cpu_ns>0);
                REQUIRE((mask&1u)?leg.array_calls>=64:leg.array_calls==0);
                REQUIRE((mask&2u)?leg.char_calls>=64:leg.char_calls==0);
                printf("bench round=%u mask=%u thread_ns=%llu process_ns=%llu array=%llu char=%llu gc=%llu\n",
                       round,mask,(unsigned long long)leg.thread_cpu_ns,(unsigned long long)leg.process_cpu_ns,
                       (unsigned long long)leg.array_calls,(unsigned long long)leg.char_calls,
                       (unsigned long long)leg.gc_cycles);
            }
        }
    } else if (!strcmp(scenario,"intrinsic_diff")) {
        init_job(&a,argv,"A","intrinsic-on",bport,base);
        init_job(&b,argv,"B","intrinsic-off",bport+1,base);
        start_job(&a); start_job(&b); join_job(&a); join_job(&b);
        printf("intrinsics A: char=%llu array=%llu gc=%llu; B: char=%llu array=%llu gc=%llu\n",
            (unsigned long long)a.char_calls,(unsigned long long)a.array_calls,(unsigned long long)a.gc_cycles,
            (unsigned long long)b.char_calls,(unsigned long long)b.array_calls,(unsigned long long)b.gc_cycles);
        REQUIRE(!a.rc && !b.rc && intrinsic_ok(&a) && intrinsic_ok(&b));
        REQUIRE(a.char_calls>=64 && a.array_calls>=64 && !b.char_calls && !b.array_calls);
        REQUIRE(a.gc_cycles>0 && b.gc_cycles>0);
    } else
#endif
    if (!strcmp(scenario,"residual_diff")) {
        char residual_app[2048];
        int len=snprintf(residual_app,sizeof residual_app,"%s/../residual",argv[3]);
        REQUIRE(len>0&&(size_t)len<sizeof residual_app);
        init_job(&a,argv,"A","residual",bport,base);
        init_job(&b,argv,"B","residual",bport+1,base);
        b.app=residual_app;
        start_job(&a); start_job(&b); join_job(&a); join_job(&b);
        REQUIRE(!a.rc&&!b.rc&&residual_equal(&a,&b));
    } else if (!strcmp(scenario, "pair")) {
        init_job(&a, argv, "A", "short", bport, base); init_job(&b, argv, "B", "short", bport+1, base);
        start_job(&a); start_job(&b); join_job(&a); join_job(&b);
        REQUIRE(!a.rc && !b.rc && result_ok(&a) && result_ok(&b));
    } else if (!strcmp(scenario, "stop_a")) {
        init_job(&a, argv, "A", "long", bport, base); init_job(&b, argv, "B", "long", bport+1, base);
        start_job(&a); start_job(&b);
        REQUIRE(wait_progress(&a, -1) >= 0 && wait_progress(&b, -1) >= 0);
        REQUIRE(stop_job(&a)); join_job(&a);
        long after = wait_progress(&b, -1); REQUIRE(after >= 0 && wait_progress(&b, after) >= 0);
        REQUIRE(stop_job(&b)); join_job(&b);
        REQUIRE(result_ok(&a) && result_ok(&b));
    } else if (!strcmp(scenario, "restart")) {
        init_job(&b, argv, "B", "long", bport+1, base); start_job(&b);
        REQUIRE(wait_progress(&b, -1) >= 0);
        init_job(&a, argv, "A", "short", bport, base); start_job(&a); join_job(&a);
        REQUIRE(!a.rc && result_ok(&a));
        init_job(&a2, argv, "A2", "short", bport+2, base); start_job(&a2); join_job(&a2);
        REQUIRE(!a2.rc && result_ok(&a2));
        long after = wait_progress(&b, -1); REQUIRE(after >= 0 && wait_progress(&b, after) >= 0);
        REQUIRE(stop_job(&b)); join_job(&b);
        REQUIRE(result_ok(&b));
    } else return 2;
    printf("%s: PASS\n", scenario); return 0;
}
