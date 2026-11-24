#ifndef JARBOX_2D_POLICY_H
#define JARBOX_2D_POLICY_H
#include <stddef.h>
#include <string.h>

#ifndef JARBOX_2D_ONLY_RUNTIME
#define JARBOX_2D_ONLY_RUNTIME 0
#endif

// Unknown archives are exclusive too. An exclusive owner remains reserved
// until all native cleanup and registry retirement have completed.
static inline int jarbox_3d_conflict(unsigned active, int existing_exclusive,
                                     int requested_exclusive) {
    return active != 0 && (existing_exclusive || requested_exclusive);
}
static inline int jarbox_legacy_3d_allowed(unsigned session_cap, int exclusive) {
    return session_cap != 0 && (session_cap == 1 || exclusive) && !JARBOX_2D_ONLY_RUNTIME;
}
static inline int jarbox_class_mentions_3d(const unsigned char *bytes, size_t size) {
    static const char *const markers[] = {
        "javax/microedition/m3g", "javax.microedition.m3g",
        "com/mascotcapsule/micro3d", "com.mascotcapsule.micro3d",
        "javax/microedition/khronos", "javax.microedition.khronos",
        "mc3dBlitToGraphics", "mc3dReadCanvasPixels"
    };
    if (!bytes) return 1;
    for (size_t j = 0; j < sizeof(markers) / sizeof(markers[0]); ++j) {
        const size_t n = strlen(markers[j]);
        if (n > size) continue;
        for (size_t i = 0; i <= size - n; ++i)
            if (bytes[i] == (unsigned char)markers[j][0] &&
                memcmp(bytes + i, markers[j], n) == 0) return 1;
    }
    return 0;
}
#endif
