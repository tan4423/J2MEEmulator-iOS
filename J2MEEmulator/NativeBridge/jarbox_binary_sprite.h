#ifndef JARBOX_BINARY_SPRITE_H
#define JARBOX_BINARY_SPRITE_H
#include <stdint.h>
#include <stddef.h>
#include <string.h>
/* Bounded immutable premultiplied BGRA source. No approximate alpha blend. */
enum { JB_BIN_UNKNOWN=0, JB_BIN_REJECT=1, JB_BIN_MIXED=2, JB_BIN_OPAQUE=3, JB_BIN_CLEAR=4 };
static inline unsigned jarbox_binary_kind(const uint32_t *src,int w,int h,size_t stride) {
    if(!src || (uintptr_t)src%_Alignof(uint32_t) || w<=0 || h<=0 ||
       stride<(size_t)w || stride>1048576u/(size_t)h) return JB_BIN_REJECT;
    unsigned opaque=0,clear=0;
    for(int y=0;y<h;y++) for(int x=0;x<w;x++) {
        uint32_t p=src[(size_t)y*stride+x];
        if(p==0) clear=1;
        else if((p>>24)==255) opaque=1;
        else return JB_BIN_REJECT;
    }
    return opaque?(clear?JB_BIN_MIXED:JB_BIN_OPAQUE):JB_BIN_CLEAR;
}
typedef struct {int x,y,sx,sy,w,h;} JarBoxBinaryRect;
/* All coordinates are integer, clip already intersected with the canvas. */
static inline int jarbox_binary_rect(JarBoxBinaryRect *o,int64_t x,int64_t y,int sx,int sy,int w,int h,
        int iw,int ih,int dw,int dh,int l,int top,int r,int b) {
    if(w<=0 || h<=0 || sx<0 || sy<0 || iw<=0 || ih<=0 || dw<=0 || dh<=0 ||
       (int64_t)sx+w>iw || (int64_t)sy+h>ih || x<INT32_MIN || x>INT32_MAX || y<INT32_MIN || y>INT32_MAX ||
       l<0 || top<0 || r>dw || b>dh || l>r || top>b) return 0;
    int64_t left=x>l?x:l, up=y>top?y:top, right=x+w<r?x+w:r, bottom=y+h<b?y+h:b;
    if(right<=left || bottom<=up) {*o=(JarBoxBinaryRect){0};return 1;}
    *o=(JarBoxBinaryRect){(int)left,(int)up,sx+(int)(left-x),sy+(int)(up-y),(int)(right-left),(int)(bottom-up)};
    return 1;
}
/* Source and destination are nonaliasing, validated by caller. */
static inline void jarbox_binary_blit(uint32_t *dst,size_t ds,const uint32_t *src,size_t ss,int w,int h,unsigned kind) {
    if(kind==JB_BIN_CLEAR)return;
    for(int y=0;y<h;y++) {
        uint32_t *d=dst+(size_t)y*ds;
        const uint32_t *s=src+(size_t)y*ss;
        if(kind==JB_BIN_OPAQUE) memcpy(d,s,(size_t)w*sizeof(*d));
        else for(int x=0;x<w;x++) {uint32_t m=0u-(s[x]>>31);d[x]=(s[x]&m)|(d[x]&~m);}
    }
}
#endif
