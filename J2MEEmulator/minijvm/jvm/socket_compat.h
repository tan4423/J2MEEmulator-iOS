#ifndef JARBOX_SOCKET_COMPAT_H
#define JARBOX_SOCKET_COMPAT_H

// A nonblocking OS query, called only when the game's existing Java code
// invokes InputStream.available(). Do not poll and do not consume bytes.
#if defined(_WIN32)
#include <winsock2.h>
static inline int jarbox_socket_bytes_available(int fd) {
    if (fd < 0) return 0;
    u_long bytes = 0;
    if (ioctlsocket((SOCKET)fd, FIONREAD, &bytes) != 0) return 0;
    return bytes > 0x7fffffffUL ? 0x7fffffff : (int)bytes;
}
#else
#include <sys/types.h>
#include <sys/ioctl.h>
static inline int jarbox_socket_bytes_available(int fd) {
    if (fd < 0) return 0;
    int bytes = 0;
    if (ioctl(fd, FIONREAD, &bytes) != 0) return 0;
    return bytes > 0 ? bytes : 0;
}
#endif

#endif
