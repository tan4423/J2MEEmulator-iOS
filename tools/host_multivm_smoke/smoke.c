/* Headless real MiniJVM integration. Only the job owner destroys its VM. */
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/stat.h>
#include "jvm.h"
#include "jvm_util.h"
#include "arraylist.h"
#include "garbage.h"

typedef struct { const char *rt, *api, *app, *tag, *mode; char save[512]; int port;
    MiniJVM *jvm; pthread_t th; pthread_mutex_t lock; atomic_int finished;
    int stop_requested, rc; } Job;

static void request_vm_stop(MiniJVM *vm) {
    vm->collector->exit_flag = 1;
    jarbox_session_begin_stop(vm->session);
    gc_request_thread_status(vm->collector, GARBAGE_THREAD_STOP);
    thread_stop_all(vm);
}
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
    j->rc = call_main(vm, "SmokeMain", args);
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
    if (!strcmp(scenario, "pair")) {
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
