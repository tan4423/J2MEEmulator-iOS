/* Host smoke test: N real MiniJVM instances on N pthreads, headless.
 * usage: smoke <rt.jar> <api.jar> <app.jar-or-dir> <scenario> */
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/stat.h>
#include "jvm.h"
#include "jvm_util.h"
#include "arraylist.h"
#include "garbage.h"

typedef struct { const char *rt, *api, *app; const char *tag, *mode; char save[512]; int port;
                 MiniJVM *jvm; pthread_t th; volatile int started, finished; int rc; } Job;

static void *job_main(void *p) {
    Job *j = p; char boot[1024], cp[2048], portbuf[16];
    snprintf(boot, sizeof boot, "%s", j->rt);
    snprintf(cp, sizeof cp, "%s:%s", j->api, j->app);
    snprintf(portbuf, sizeof portbuf, "%d", j->port);
    MiniJVM *jvm = jvm_create();
    if (!jvm) { j->rc = -2; j->finished = 1; return NULL; }
    jvm->jdwp_enable = 0; jvm->max_heap_size = 64 * 1024 * 1024;
    jvm->garbage_collect_period_ms = 200; jvm->heap_overload_percent = 70;
    if (jvm_init(jvm, boot, cp)) { j->rc = -3; jvm_destroy(jvm); j->finished = 1; return NULL; }
    j->jvm = jvm; j->started = 1;
    ArrayList *args = arraylist_create(0);
    arraylist_push_back(args, (void *)j->tag); arraylist_push_back(args, (void *)j->save);
    arraylist_push_back(args, (void *)j->mode); arraylist_push_back(args, (void *)portbuf);
    j->rc = call_main(jvm, "SmokeMain", args);
    arraylist_destroy(args);
    if (strcmp(j->mode, "long") != 0) { jvm->collector->exit_flag = 1; thread_stop_all(jvm); jvm_destroy(jvm); j->jvm = NULL; }
    j->finished = 1; return NULL;
}

static void stop_job(Job *j) {
    if (!j->jvm) return;
    MiniJVM *jvm = j->jvm; jvm->collector->exit_flag = 1; thread_stop_all(jvm);
    jvm_destroy(jvm); j->jvm = NULL;
}

static int file_has(const char *dir, const char *needle) {
    char path[1024]; snprintf(path, sizeof path, "%s/state.txt", dir);
    FILE *f = fopen(path, "r"); if (!f) return 0; char buf[256] = {0}; fread(buf, 1, 255, f); fclose(f);
    return strstr(buf, needle) != NULL;
}

static void init_job(Job *j, char **a, const char *tag, const char *mode, int port, const char *base) {
    memset(j, 0, sizeof *j); j->rt = a[1]; j->api = a[2]; j->app = a[3];
    j->tag = tag; j->mode = mode; j->port = port;
    snprintf(j->save, sizeof j->save, "%s/%s", base, tag); mkdir(j->save, 0755);
    char p[600]; snprintf(p, sizeof p, "%s/state.txt", j->save); unlink(p);
}

void smoke_install_crash_handler(void);
int main(int argc, char **argv) {
    smoke_install_crash_handler();
    if (argc < 5) { fprintf(stderr, "usage\n"); return 2; }
    const char *scenario = argv[4]; char base[256]; snprintf(base, sizeof base, "/tmp/jbsmoke.%d", getpid()); mkdir(base, 0755);
    int fails = 0; int bport = 20000 + (getpid() % 20000);
    if (!strcmp(scenario, "pair")) {            /* two JVMs fully concurrent */
        Job a, b; init_job(&a, argv, "A", "short", bport, base); init_job(&b, argv, "B", "short", bport + 1, base);
        pthread_create(&a.th, 0, job_main, &a); pthread_create(&b.th, 0, job_main, &b);
        pthread_join(a.th, 0); pthread_join(b.th, 0);
        if (a.rc || b.rc || !file_has(a.save, "tag=A") || !file_has(b.save, "tag=B")) { fprintf(stderr, "PAIR FAIL rc=%d,%d\n", a.rc, b.rc); fails++; }
    } else if (!strcmp(scenario, "stop_a")) {   /* stop A mid-run, B must complete */
        Job a, b; init_job(&a, argv, "A", "long", bport, base); init_job(&b, argv, "B", "short", bport + 1, base);
        pthread_create(&a.th, 0, job_main, &a);
        for (int i = 0; i < 300 && !file_has(a.save, "tag=A"); i++) usleep(20000);
        pthread_create(&b.th, 0, job_main, &b);
        usleep(30000); stop_job(&a); pthread_join(a.th, 0);
        pthread_join(b.th, 0);
        if (b.rc || !file_has(b.save, "tag=B")) { fprintf(stderr, "STOP_A FAIL: B rc=%d\n", b.rc); fails++; }
    } else if (!strcmp(scenario, "restart")) {  /* A runs, dies, restarts while B alive */
        Job a, b; init_job(&b, argv, "B", "long", bport + 1, base); init_job(&a, argv, "A", "short", bport, base);
        pthread_create(&b.th, 0, job_main, &b);
        pthread_create(&a.th, 0, job_main, &a); pthread_join(a.th, 0);
        Job a2; init_job(&a2, argv, "A2", "short", bport + 2, base);
        pthread_create(&a2.th, 0, job_main, &a2); pthread_join(a2.th, 0);
        if (a.rc || a2.rc || !file_has(a2.save, "tag=A2")) { fprintf(stderr, "RESTART FAIL rc=%d,%d\n", a.rc, a2.rc); fails++; }
        stop_job(&b); pthread_join(b.th, 0);
    } else { fprintf(stderr, "unknown scenario\n"); return 2; }
    printf("%s: %s\n", scenario, fails ? "FAIL" : "PASS");
    return fails ? 1 : 0;
}
