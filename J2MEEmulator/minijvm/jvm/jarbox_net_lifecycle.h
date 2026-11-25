#ifndef JARBOX_NET_LIFECYCLE_H
#define JARBOX_NET_LIFECYCLE_H
#include "jarbox_session.h"

/* A native call borrows its live session, never a Java heap pointer.
 * All registered fds are owned until normal close or final VM drain.
 * Stop shuts down transport immediately, but does not recycle fd numbers
 * while a Java worker may still be inside a native syscall. */
typedef struct {
    JarBoxSession *owner;
    int timeout_ms;
} JarBoxNetScope;

JarBoxNetScope jarbox_net_scope_enter(JarBoxSession *owner, int timeout_ms);
void jarbox_net_scope_leave(JarBoxNetScope prior);
unsigned jarbox_net_stop_owner(JarBoxSession *owner);
unsigned jarbox_net_release_owner(JarBoxSession *owner);
int jarbox_net_duplicate_for_tls(int fd);
// Serialize half-shutdown with context close. No descriptor reuse window.
int jarbox_net_shutdown_fd(int *fd, int direction);
/* Thread-local, nested request scope; nonzero failure stays sticky until end.
 * No Java references or payloads retained. 1=connect timeout, 2=read timeout. */
int jarbox_net_http_begin(JarBoxSession *owner, int connect_ms, int read_ms);
int jarbox_net_http_end(JarBoxSession *owner);
int jarbox_net_http_status(void);
int jarbox_net_http_read_ms(void);
int jarbox_net_http_fail(int kind, int *fd);
#endif
