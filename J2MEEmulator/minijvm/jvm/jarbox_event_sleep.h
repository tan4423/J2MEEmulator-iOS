#ifndef JARBOX_EVENT_SLEEP_H
#define JARBOX_EVENT_SLEEP_H
static s64 jarbox_event_sleep(Runtime *runtime, s64 ms) {
    JavaThreadInfo *info=runtime->thrd_info;
    JarBoxMonitorWaiter waiter={0};
    if (mtx_init(&waiter.mutex,mtx_plain)!=thrd_success) return ms;
    if (cnd_init(&waiter.cond)!=thrd_success) { mtx_destroy(&waiter.mutex); return ms; }
    struct timespec now;
    if (clock_gettime(CLOCK_MONOTONIC,&now)!=0) goto cleanup;
    const s64 deadline=(s64)now.tv_sec*INT64_C(1000000000)+now.tv_nsec+ms*INT64_C(1000000);
    spin_lock(&info->lock);
    if (info->is_stop || info->is_interrupt) {
        spin_unlock(&info->lock);
        ms=0;
        goto cleanup;
    }
    info->sleep_waiter=&waiter;
    spin_unlock(&info->lock);
    mtx_lock(&waiter.mutex);
    while (!waiter.done) {
        if (clock_gettime(CLOCK_MONOTONIC,&now)!=0) break;
        s64 left=deadline-((s64)now.tv_sec*INT64_C(1000000000)+now.tv_nsec);
        if (left<=0) { ms=0; break; }
        // Preserve the remaining delay if the native wait fails. Use a
        // monotonic relative deadline on iOS, independent of wall-clock changes.
        ms=(left+999999)/1000000;
        struct timespec delay={.tv_sec=left/1000000000,.tv_nsec=left%1000000000};
#if defined(__APPLE__)
        int rc=pthread_cond_timedwait_relative_np(&waiter.cond,&waiter.mutex,&delay);
#else
        // POSIX host test fallback; this experimental tier targets iOS.
        struct timespec absolute;
        if (clock_gettime(CLOCK_REALTIME,&absolute)!=0) break;
        absolute.tv_sec+=delay.tv_sec;
        absolute.tv_nsec+=delay.tv_nsec;
        if (absolute.tv_nsec>=1000000000L) { ++absolute.tv_sec; absolute.tv_nsec-=1000000000L; }
        int rc=pthread_cond_timedwait(&waiter.cond,&waiter.mutex,&absolute);
#endif
        if (rc!=0 && rc!=ETIMEDOUT && rc!=EINTR) break;
    }
    if (waiter.done) ms=0;
    mtx_unlock(&waiter.mutex);
    // Same publication order as monitor wait: no waiter mutex held while
    // detaching. Stop/interrupt cannot access the stack node after this.
    spin_lock(&info->lock);
    info->sleep_waiter=NULL;
    if (info->is_stop || info->is_interrupt) ms=0;
    spin_unlock(&info->lock);
cleanup:
    cnd_destroy(&waiter.cond);
    mtx_destroy(&waiter.mutex);
    return ms;
}
#endif
