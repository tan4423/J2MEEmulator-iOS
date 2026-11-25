#ifndef JARBOX_AMBIENT_PCM_H
#define JARBOX_AMBIENT_PCM_H
#include <stdint.h>
#include <stddef.h>
#include <math.h>
#include <string.h>

// Original quiet ambient chord, four seconds, mono PCM16. Integer cycles
// across the loop, no click at the seam and no encoded media dependency.
enum { JARBOX_AMBIENT_RATE=16000, JARBOX_AMBIENT_FRAMES=64000,
       JARBOX_AMBIENT_BYTES=44+2*JARBOX_AMBIENT_FRAMES };
static inline void jarbox_ambient_le16(uint8_t *p,uint16_t x) {
    p[0]=(uint8_t)x; p[1]=(uint8_t)(x>>8);
}
static inline void jarbox_ambient_le32(uint8_t *p,uint32_t x) {
    jarbox_ambient_le16(p,(uint16_t)x); jarbox_ambient_le16(p+2,(uint16_t)(x>>16));
}
static inline int jarbox_ambient_wav(uint8_t *out,size_t len) {
    if (!out || len<JARBOX_AMBIENT_BYTES) return 0;
    memcpy(out,"RIFF",4); jarbox_ambient_le32(out+4,JARBOX_AMBIENT_BYTES-8);
    memcpy(out+8,"WAVEfmt ",8); jarbox_ambient_le32(out+16,16);
    jarbox_ambient_le16(out+20,1); jarbox_ambient_le16(out+22,1);
    jarbox_ambient_le32(out+24,JARBOX_AMBIENT_RATE);
    jarbox_ambient_le32(out+28,2*JARBOX_AMBIENT_RATE);
    jarbox_ambient_le16(out+32,2); jarbox_ambient_le16(out+34,16);
    memcpy(out+36,"data",4); jarbox_ambient_le32(out+40,2*JARBOX_AMBIENT_FRAMES);
    const double tau=6.28318530717958647692;
    for (unsigned i=0;i<JARBOX_AMBIENT_FRAMES;++i) {
        const double t=(double)i/JARBOX_AMBIENT_RATE;
        const double gain=0.65+0.35*cos(tau*t/4.0);
        const int16_t sample=(int16_t)(gain*(4200*sin(tau*220*t)+
            2300*sin(tau*330*t)+1100*sin(tau*440*t)));
        jarbox_ambient_le16(out+44+2*i,(uint16_t)sample);
    }
    return 1;
}
#endif
