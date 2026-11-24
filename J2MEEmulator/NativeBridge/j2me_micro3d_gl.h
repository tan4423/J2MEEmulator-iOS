#ifndef J2ME_MICRO3D_GL_H
#define J2ME_MICRO3D_GL_H

#include "jvm.h"

#ifdef __cplusplus
extern "C" {
#endif

/// Register all MascotCapsule micro3D OpenGL ES 2.0 native methods with the JVM.
void j2me_micro3d_gl_reg_natives(MiniJVM *jvm);

/// Release only the specified heap generation after its Java workers exit.
void j2me_micro3d_gl_cleanup_for_owner(uint64_t owner_key);

#ifdef __cplusplus
}
#endif

#endif /* J2ME_MICRO3D_GL_H */
