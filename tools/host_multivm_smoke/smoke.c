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
#if defined(JARBOX_HOST_GLYPH_LOOP_TEST)
    uint64_t glyph_loops,glyph_chars,glyph_shadow,glyph_mismatch;
#endif
#if defined(JARBOX_HOST_RENDER_ISLAND_TEST)
    uint64_t islands, island_ops, island_refusals, wrapper_skips;
#endif
#if defined(JARBOX_HOST_BLOCK_IR_TEST)
    uint64_t block_spans, block_ops, block_compiles, block_shared_hits;
    int block_hold;
    atomic_int block_release;
#endif
#if defined(JARBOX_HOST_GC_INDEX_TEST)
    uint64_t gc_index_passes, gc_index_large_snapshots, gc_index_omitted;
    uint64_t gc_deferred_visits, gc_finalizers, gc_weak_callbacks;
#endif
    uint64_t thread_cpu_ns, process_cpu_ns, residual_calls, residual_compiles, residual_deopts,residual_skipped,residual_cold_deopts,residual_suspended;
    uint64_t binding_good,binding_bad,binding_mismatch; } Job;

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
    if(!strncmp(j->mode,"residual",8)||!strcmp(j->mode,"binding"))
        snprintf(cp,sizeof cp,"%s:%s",j->app,j->api); // controlled LCDUI doubles only
    else snprintf(cp, sizeof cp, "%s:%s", j->api, j->app);
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
#if defined(JARBOX_HOST_GC_INDEX_TEST)
    vm->host_gc_index_enabled=!strcmp(j->mode,"intrinsic-gc-on") ||
                              !strcmp(j->mode,"intrinsic-gc-callbacks-on");
#endif
#if defined(JARBOX_HOST_BLOCK_IR_TEST)
    vm->host_block_ir_enabled=!strcmp(j->mode,"intrinsic-block-on");
#endif
#if defined(JARBOX_HOST_RENDER_ISLAND_TEST)
    vm->host_render_island_enabled=!strcmp(j->mode,"intrinsic-island-on");
#endif
#if defined(JARBOX_HOST_GLYPH_LOOP_TEST)
    vm->host_glyph_enabled=!strcmp(j->mode,"intrinsic-glyph-on");
#endif
    if (jvm_init(vm, (char *)j->rt, cp)) { j->rc = -3; goto cleanup; }
    pthread_mutex_lock(&j->lock);
    j->jvm = vm;
    pthread_mutex_unlock(&j->lock);
    ArrayList *args = arraylist_create(0);
    arraylist_push_back(args, (void *)j->tag); arraylist_push_back(args, (void *)j->save);
    arraylist_push_back(args, (void *)j->mode); arraylist_push_back(args, (void *)portbuf);
#if defined(JARBOX_HOST_RESIDUAL_TEST)
    vm->session->treo_state.host_residual_enabled=!strcmp(j->mode,"residual-native");
#endif
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
    const char *main_class=intrinsic?"IntrinsicMain":(!strncmp(j->mode,"residual",8)?"ResidualMain":"SmokeMain");
#if defined(JARBOX_HOST_GC_INDEX_TEST)
    if (!strncmp(j->mode,"intrinsic-gc-callbacks-",23)) main_class="GcIndexMain";
#endif
#if defined(JARBOX_HOST_BLOCK_IR_TEST)
    if(!strncmp(j->mode,"intrinsic-block-",16))main_class="BlockMain";
#endif
#if defined(JARBOX_HOST_RENDER_ISLAND_TEST)
    if(!strncmp(j->mode,"intrinsic-island-",17))main_class="RenderIslandMain";
#endif
#if defined(JARBOX_HOST_GLYPH_LOOP_TEST)
    if(!strncmp(j->mode,"intrinsic-glyph-",16))main_class="GlyphLoopMain";
#endif
    j->rc=call_main(vm,main_class,args);
    uint64_t t1=cpu_now(CLOCK_THREAD_CPUTIME_ID),p1=cpu_now(CLOCK_PROCESS_CPUTIME_ID);
    if (t0 && t1>t0) j->thread_cpu_ns=t1-t0;
    if (p0 && p1>p0) j->process_cpu_ns=p1-p0;
    j->char_calls=__atomic_load_n(&vm->session->treo_state.char_leaf_calls,__ATOMIC_RELAXED);
    j->array_calls=__atomic_load_n(&vm->session->treo_state.array_lookup_mode1_calls,__ATOMIC_RELAXED);
    j->gc_cycles=__atomic_load_n(&vm->session->treo_state.gc_worker_cycles,__ATOMIC_RELAXED);
#if defined(JARBOX_HOST_GLYPH_LOOP_TEST)
    j->glyph_loops=__atomic_load_n(&vm->host_glyph_loops,__ATOMIC_RELAXED);
    j->glyph_chars=__atomic_load_n(&vm->host_glyph_chars,__ATOMIC_RELAXED);
    j->glyph_shadow=__atomic_load_n(&vm->host_glyph_shadow,__ATOMIC_RELAXED);
    j->glyph_mismatch=__atomic_load_n(&vm->host_glyph_mismatch,__ATOMIC_RELAXED);
#endif
#if defined(JARBOX_HOST_RENDER_ISLAND_TEST)
    j->islands=__atomic_load_n(&vm->host_render_island_skips,__ATOMIC_RELAXED);
    j->island_ops=__atomic_load_n(&vm->host_render_island_ops,__ATOMIC_RELAXED);
    j->island_refusals=__atomic_load_n(&vm->host_render_island_refusals,__ATOMIC_RELAXED);
    j->wrapper_skips=__atomic_load_n(&vm->host_render_wrapper_skips,__ATOMIC_RELAXED);
#endif
#if defined(JARBOX_HOST_BLOCK_IR_TEST)
    j->block_spans=__atomic_load_n(&vm->host_block_ir_spans,__ATOMIC_RELAXED);
    j->block_ops=__atomic_load_n(&vm->host_block_ir_ops,__ATOMIC_RELAXED);
    j->block_compiles=__atomic_load_n(&vm->host_block_ir_compiles,__ATOMIC_RELAXED);
    j->block_shared_hits=__atomic_load_n(&vm->block_ir_shared_hits,__ATOMIC_RELAXED);
#endif
#if defined(JARBOX_HOST_GC_INDEX_TEST)
    j->gc_index_passes=__atomic_load_n(&vm->collector->host_gc_index_passes,__ATOMIC_RELAXED);
    j->gc_index_large_snapshots=__atomic_load_n(&vm->collector->host_gc_index_large_snapshots,__ATOMIC_RELAXED);
    j->gc_index_omitted=__atomic_load_n(&vm->collector->host_gc_index_omitted,__ATOMIC_RELAXED);
    j->gc_deferred_visits=__atomic_load_n(&vm->collector->host_gc_deferred_visits,__ATOMIC_RELAXED);
    j->gc_finalizers=__atomic_load_n(&vm->collector->host_gc_finalizers,__ATOMIC_RELAXED);
    j->gc_weak_callbacks=__atomic_load_n(&vm->collector->host_gc_weak_callbacks,__ATOMIC_RELAXED);
#endif
#else
    j->rc = call_main(vm, !strncmp(j->mode,"residual",8)?"ResidualMain":(!strcmp(j->mode,"binding")?"BindingMain":"SmokeMain"), args);
#endif
#if defined(JARBOX_HOST_RESIDUAL_TEST)
    j->residual_calls=__atomic_load_n(&vm->session->treo_state.host_residual_calls,__ATOMIC_RELAXED);
    j->residual_compiles=__atomic_load_n(&vm->session->treo_state.host_residual_compiles,__ATOMIC_RELAXED);
    j->residual_suspended=__atomic_load_n(&vm->session->treo_state.host_residual_suspended,__ATOMIC_RELAXED);
    j->residual_deopts=__atomic_load_n(&vm->session->treo_state.host_residual_deopts,__ATOMIC_RELAXED);
    j->residual_skipped=__atomic_load_n(&vm->session->treo_state.host_residual_skipped,__ATOMIC_RELAXED);
    j->residual_cold_deopts=__atomic_load_n(&vm->session->treo_state.host_residual_cold_deopts,__ATOMIC_RELAXED);
#endif
#if defined(JARBOX_HOST_BINDING_TEST)
    j->binding_good=__atomic_load_n(&vm->session->treo_state.host_binding_good,__ATOMIC_RELAXED);
    j->binding_bad=__atomic_load_n(&vm->session->treo_state.host_binding_bad,__ATOMIC_RELAXED);
    j->binding_mismatch=__atomic_load_n(&vm->session->treo_state.host_binding_mismatch,__ATOMIC_RELAXED);
#endif
    arraylist_destroy(args);
#if defined(JARBOX_HOST_BLOCK_IR_TEST)
    // Keep A's owning CodeAttributes alive until B has completed. The
    // sharing gate must test overlapping leases, not a scheduler lottery.
    if(j->block_hold){
        for(unsigned i=0;i<6000&&!atomic_load_explicit(&j->block_release,memory_order_acquire);++i)
            usleep(10000);
    }
#endif
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
#if defined(JARBOX_HOST_GC_INDEX_TEST)
static int gc_callbacks_ok(const Job *j) {
    char path[1024],buf[128]={0};
    const char *expected="PASS 192 383976000\n"; // OpenJDK fixture oracle
    snprintf(path,sizeof path,"%s/gc-index.txt",j->save);
    FILE *f=fopen(path,"r"); if(!f)return 0;
    size_t n=fread(buf,1,sizeof buf-1,f); fclose(f);
    return n==strlen(expected)&&!memcmp(buf,expected,n);
}
#endif
#if defined(JARBOX_HOST_BLOCK_IR_TEST)
static int block_ok(const Job *j) {
    char path[1024],buf[128]={0};
    const char *expected="PASS 8000 8966399143674533008\n"; // independent OpenJDK -Xint oracle
    snprintf(path,sizeof path,"%s/block.txt",j->save);
    FILE *f=fopen(path,"r");if(!f)return 0;
    size_t n=fread(buf,1,sizeof buf-1,f);fclose(f);
    return n==strlen(expected)&&!memcmp(buf,expected,n);
}
#endif
#if defined(JARBOX_HOST_RENDER_ISLAND_TEST)
static int island_ok(const Job *j){
    char path[1024],buf[128]={0};
    snprintf(path,sizeof path,"%s/island.txt",j->save);
    FILE *f=fopen(path,"r");if(!f)return 0;
    size_t n=fread(buf,1,sizeof buf-1,f);fclose(f);
    const char *expected="PASS 8000\n";
    return n==strlen(expected)&&!memcmp(buf,expected,n);
}
#endif
#if defined(JARBOX_HOST_GLYPH_LOOP_TEST)
static int glyph_ok(const Job *j){
    char path[1024],buf[128]={0};
    snprintf(path,sizeof path,"%s/glyph.txt",j->save);
    FILE *f=fopen(path,"r");if(!f)return 0;
    size_t n=fread(buf,1,sizeof buf-1,f);fclose(f);
    const char *expected="PASS 8000\n";
    return n==strlen(expected)&&!memcmp(buf,expected,n);
}
#endif
static int residual_equal(const Job *a,const Job *b) {
    char p[1024],q[1024],x[65536],y[65536];
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
               fault<0||fault>4)break;
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
#if defined(JARBOX_HOST_BLOCK_IR_TEST)
    atomic_init(&j->block_release,0);
#endif
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
#if defined(JARBOX_HOST_GC_INDEX_TEST)
    if (!strcmp(scenario,"gc_index_callbacks")) {
        init_job(&a,argv,"A","intrinsic-gc-callbacks-off",bport,base);
        init_job(&b,argv,"B","intrinsic-gc-callbacks-on",bport+1,base);
        start_job(&a); start_job(&b); join_job(&a); join_job(&b);
        REQUIRE(!a.rc && !b.rc && gc_callbacks_ok(&a) && gc_callbacks_ok(&b));
        REQUIRE(a.gc_cycles>0 && b.gc_cycles>0 && a.gc_index_passes==0 && b.gc_index_passes>0);
        REQUIRE(!a.char_calls && !b.char_calls && !a.array_calls && !b.array_calls);
        REQUIRE(a.gc_deferred_visits>0 && b.gc_deferred_visits>0);
        REQUIRE(a.gc_finalizers>=192 && b.gc_finalizers>=192);
        REQUIRE(a.gc_weak_callbacks>=192 && b.gc_weak_callbacks>=192);
        REQUIRE(!a.gc_index_large_snapshots && !a.gc_index_omitted);
        REQUIRE(b.gc_index_large_snapshots>0 && b.gc_index_omitted>=10000);
        printf("gc callbacks A visits=%llu finalizers=%llu weak=%llu cycles=%llu\n",
               (unsigned long long)a.gc_deferred_visits,(unsigned long long)a.gc_finalizers,
               (unsigned long long)a.gc_weak_callbacks,(unsigned long long)a.gc_cycles);
        printf("gc callbacks B visits=%llu finalizers=%llu weak=%llu cycles=%llu indexed=%llu large_snapshots=%llu omitted=%llu\n",
               (unsigned long long)b.gc_deferred_visits,(unsigned long long)b.gc_finalizers,
               (unsigned long long)b.gc_weak_callbacks,(unsigned long long)b.gc_cycles,
               (unsigned long long)b.gc_index_passes,(unsigned long long)b.gc_index_large_snapshots,
               (unsigned long long)b.gc_index_omitted);
    } else if (!strcmp(scenario,"gc_index_diff")) {
        init_job(&a,argv,"A","intrinsic-gc-off",bport,base);
        init_job(&b,argv,"B","intrinsic-gc-on",bport+1,base);
        start_job(&a); start_job(&b); join_job(&a); join_job(&b);
        REQUIRE(!a.rc && !b.rc && intrinsic_ok(&a) && intrinsic_ok(&b));
        REQUIRE(a.gc_cycles>0 && b.gc_cycles>0 && a.gc_index_passes==0 && b.gc_index_passes>0);
        REQUIRE(!a.char_calls && !b.char_calls && !a.array_calls && !b.array_calls);
        printf("gc index A=%llu/%llu B=%llu/%llu\n",
            (unsigned long long)a.gc_index_passes,(unsigned long long)a.gc_cycles,
            (unsigned long long)b.gc_index_passes,(unsigned long long)b.gc_cycles);
    } else
#endif
#if defined(JARBOX_HOST_BLOCK_IR_TEST)
    if(!strcmp(scenario,"block_ir_share")){
        init_job(&a,argv,"A","intrinsic-block-on",bport,base);
        init_job(&b,argv,"B","intrinsic-block-on",bport+1,base);
        a.block_hold=1;start_job(&a);
        int published=0;
        for(unsigned i=0;i<2000&&!published;++i){
            pthread_mutex_lock(&a.lock);
            published=a.jvm&&__atomic_load_n(&a.jvm->block_ir_plans,__ATOMIC_ACQUIRE)>=4;
            pthread_mutex_unlock(&a.lock);
            if(!published)usleep(10000);
        }
        start_job(&b);join_job(&b);
        atomic_store_explicit(&a.block_release,1,memory_order_release);join_job(&a);
        REQUIRE(published);
        REQUIRE(!a.rc&&!b.rc&&block_ok(&a)&&block_ok(&b));
        REQUIRE(a.gc_cycles>0&&b.gc_cycles>0);
        REQUIRE(a.block_spans>=8000&&b.block_spans>=8000);
        REQUIRE(a.block_compiles>=3&&b.block_compiles>=3);
        REQUIRE(a.block_shared_hits+b.block_shared_hits>=3);
        printf("block shared A=%llu B=%llu (exact plan hits)\n",
               (unsigned long long)a.block_shared_hits,(unsigned long long)b.block_shared_hits);
    } else if(!strcmp(scenario,"block_ir_diff")){
        init_job(&a,argv,"A","intrinsic-block-off",bport,base);
        init_job(&b,argv,"B","intrinsic-block-on",bport+1,base);
        start_job(&a);start_job(&b);join_job(&a);join_job(&b);
        REQUIRE(!a.rc&&!b.rc&&block_ok(&a)&&block_ok(&b));
        REQUIRE(a.gc_cycles>0&&b.gc_cycles>0);
        REQUIRE(!a.block_spans&&!a.block_ops&&!a.block_compiles);
        REQUIRE(b.block_compiles>=3&&b.block_spans>=8000&&b.block_ops>=4*b.block_spans);
        REQUIRE(!a.char_calls&&!b.char_calls&&!a.array_calls&&!b.array_calls);
        printf("block IR A=%llu/%llu/%llu B=%llu/%llu/%llu (spans/ops/compiles)\n",
               (unsigned long long)a.block_spans,(unsigned long long)a.block_ops,(unsigned long long)a.block_compiles,
               (unsigned long long)b.block_spans,(unsigned long long)b.block_ops,(unsigned long long)b.block_compiles);
    } else
#endif
#if defined(JARBOX_HOST_RENDER_ISLAND_TEST)
    if(!strcmp(scenario,"render_island_diff")){
        init_job(&a,argv,"A","intrinsic-island-off",bport,base);
        init_job(&b,argv,"B","intrinsic-island-on",bport+1,base);
        start_job(&a);start_job(&b);join_job(&a);join_job(&b);
        REQUIRE(!a.rc&&!b.rc&&island_ok(&a)&&island_ok(&b));
        REQUIRE(!a.islands&&!a.island_ops&&!a.island_refusals&&!a.wrapper_skips);
        REQUIRE(b.islands>=7900&&b.islands<=8000&&b.island_ops>=8*b.islands&&b.island_refusals>=8000);
        REQUIRE(a.gc_cycles>0&&b.gc_cycles>0);
        REQUIRE(b.wrapper_skips>=3900&&b.wrapper_skips<=4000);
        printf("render islands B=%llu ops=%llu refusals=%llu wrapper_only=%llu\n",
               (unsigned long long)b.islands,(unsigned long long)b.island_ops,(unsigned long long)b.island_refusals,(unsigned long long)b.wrapper_skips);
    } else
#endif
#if defined(JARBOX_HOST_GLYPH_LOOP_TEST)
    if(!strcmp(scenario,"glyph_loop_diff")){
        init_job(&a,argv,"A","intrinsic-glyph-off",bport,base);
        init_job(&b,argv,"B","intrinsic-glyph-on",bport+1,base);
        start_job(&a);start_job(&b);join_job(&a);join_job(&b);
        REQUIRE(!a.rc&&!b.rc&&glyph_ok(&a)&&glyph_ok(&b));
        printf("glyph A shadow=%llu mismatch=%llu B loops=%llu chars=%llu\n",
            (unsigned long long)a.glyph_shadow,(unsigned long long)a.glyph_mismatch,
            (unsigned long long)b.glyph_loops,(unsigned long long)b.glyph_chars);
        REQUIRE(!a.glyph_loops&&!a.glyph_chars&&!a.glyph_mismatch&&!b.glyph_mismatch);
        REQUIRE(a.glyph_shadow>=3900&&a.glyph_shadow<=4000);
        REQUIRE(b.glyph_loops>=3900&&b.glyph_loops<=4000&&b.glyph_chars==5*b.glyph_loops);
        REQUIRE(a.gc_cycles>0&&b.gc_cycles>0);
    } else
#endif
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
#if defined(JARBOX_HOST_BINDING_TEST)
    if(!strcmp(scenario,"binding_diff")) {
        init_job(&a,argv,"A","binding",bport,base);
        init_job(&b,argv,"B","binding",bport+1,base);
        start_job(&a);start_job(&b);join_job(&a);join_job(&b);
        printf("binding A: good=%llu bad=%llu mismatch=%llu\n",(unsigned long long)a.binding_good,(unsigned long long)a.binding_bad,(unsigned long long)a.binding_mismatch);
        printf("binding B: good=%llu bad=%llu mismatch=%llu\n",(unsigned long long)b.binding_good,(unsigned long long)b.binding_bad,(unsigned long long)b.binding_mismatch);
        REQUIRE(!a.rc&&!b.rc&&a.binding_good==4000&&b.binding_good==4000&&
                a.binding_bad==38000&&b.binding_bad==38000&&!a.binding_mismatch&&!b.binding_mismatch);
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
    }
#if defined(JARBOX_HOST_RESIDUAL_TEST)
    else if (!strcmp(scenario,"residual_native_diff") || !strcmp(scenario,"residual_resume_diff") || !strcmp(scenario,"residual_closed_diff") || !strcmp(scenario,"residual_extended_diff") || !strcmp(scenario,"residual_wide_diff") || !strcmp(scenario,"residual_background_diff")) {
        // Both VMs load the original fixture, only B admits the native plan.
        init_job(&a,argv,"A","residual",bport,base);
        init_job(&b,argv,"B","residual-native",bport+1,base);
        start_job(&a); start_job(&b); join_job(&a); join_job(&b);
        printf("residual native calls: A=%llu B=%llu\n",
               (unsigned long long)a.residual_calls,(unsigned long long)b.residual_calls);
        printf("residual native compiles: A=%llu B=%llu\n",
               (unsigned long long)a.residual_compiles,(unsigned long long)b.residual_compiles);
        printf("residual native deopts: A=%llu B=%llu\n",(unsigned long long)a.residual_deopts,(unsigned long long)b.residual_deopts);
        const int extended=!strcmp(scenario,"residual_extended_diff")||!strcmp(scenario,"residual_wide_diff")||!strcmp(scenario,"residual_background_diff");
        const int closed=extended||!strcmp(scenario,"residual_closed_diff");
        unsigned admitted=2000;
        if(closed){admitted=0;for(unsigned i=0;i<2000;i++)if(i%53&&i%59)++admitted;}
        printf("residual native skipped: A=%llu B=%llu\n",(unsigned long long)a.residual_skipped,(unsigned long long)b.residual_skipped);
        printf("residual native suspended: A=%llu B=%llu\n",(unsigned long long)a.residual_suspended,(unsigned long long)b.residual_suspended);
        // Every missing eligible invocation must be explicitly attributed
        // to the suspend guard, and all outputs still must match exactly.
        // Refuse a vacuous run dominated by suspension or fallback.
        REQUIRE(!a.rc&&!b.rc&&a.residual_calls==0&&a.residual_suspended==0&&
                b.residual_calls+b.residual_suspended==admitted&&b.residual_calls>=admitted*95u/100u&&
                a.residual_compiles==0&&b.residual_compiles==1&&residual_equal(&a,&b));
        REQUIRE(a.residual_deopts==0&&((closed||!strcmp(scenario,"residual_resume_diff"))?
                (b.residual_deopts>0&&b.residual_deopts<admitted):b.residual_deopts==0));
        REQUIRE(a.residual_skipped==0&&(closed?b.residual_skipped>0:b.residual_skipped==0));
        printf("residual cold deopts: A=%llu B=%llu\n",(unsigned long long)a.residual_cold_deopts,(unsigned long long)b.residual_cold_deopts);
        REQUIRE(a.residual_cold_deopts==0&&(extended?b.residual_cold_deopts<=b.residual_deopts:closed?b.residual_cold_deopts==1:b.residual_cold_deopts==0));
    }
#endif
    else if (!strcmp(scenario, "pair")) {
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
