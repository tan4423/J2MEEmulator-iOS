/* Apple-only independent pixel oracle, including mixed CG/software order. */
#include <CoreGraphics/CoreGraphics.h>
#include "jarbox_binary_sprite.h"
#include <assert.h>
#include <stdio.h>
static uint32_t seed=1;
static uint32_t next(void){seed=seed*1664525u+1013904223u;return seed;}
static CGContextRef context(uint32_t *p,int w,int h,CGColorSpaceRef cs){
    CGContextRef c=CGBitmapContextCreate(p,w,h,8,w*4,cs,kCGImageAlphaPremultipliedFirst|kCGBitmapByteOrder32Little);
    assert(c);CGContextTranslateCTM(c,0,h);CGContextScaleCTM(c,1,-1);return c;
}
static void draw(CGContextRef c,CGImageRef crop,int x,int y,int w,int h){
    CGContextSaveGState(c);CGContextTranslateCTM(c,x,y);CGContextTranslateCTM(c,0,h);CGContextScaleCTM(c,1,-1);
    CGContextDrawImage(c,CGRectMake(0,0,w,h),crop);CGContextRestoreGState(c);
}
int main(void){
    CGColorSpaceRef cs=CGColorSpaceCreateDeviceRGB();assert(cs);
    uint32_t pixels[64],reference[16*16],candidate[16*16];
    for(unsigned n=0;n<4000;n++){
        unsigned kind=2+n%3;
        for(unsigned i=0;i<64;i++){uint32_t v=next();pixels[i]=kind==JB_BIN_CLEAR||(kind==JB_BIN_MIXED&&(v&1))?0:v|0xff000000u;}
        CGContextRef source=CGBitmapContextCreate(pixels,8,8,8,32,cs,kCGImageAlphaPremultipliedFirst|kCGBitmapByteOrder32Little);
        assert(source);CGImageRef image=CGBitmapContextCreateImage(source);assert(image);
        for(unsigned i=0;i<256;i++){uint32_t v=next();reference[i]=candidate[i]=(i&1)?v|0xff000000u:0;}
        CGContextRef a=context(reference,16,16,cs),b=context(candidate,16,16,cs);
        int l=n%4,t=(n/4)%4,r=16-(n/16)%4,bot=16-(n/64)%4;
        CGContextClipToRect(a,CGRectMake(l,t,r-l,bot-t));CGContextClipToRect(b,CGRectMake(l,t,r-l,bot-t));
        for(unsigned j=0;j<4;j++){
            int x=(int)(next()%24)-8,y=(int)(next()%24)-8,sx=next()%8,sy=next()%8;
            int w=1+next()%(8-sx),h=1+next()%(8-sy);
            CGImageRef crop=CGImageCreateWithImageInRect(image,CGRectMake(sx,sy,w,h));assert(crop);
            draw(a,crop,x,y,w,h);
            if(j&1)draw(b,crop,x,y,w,h);else{
                JarBoxBinaryRect p;assert(jarbox_binary_rect(&p,x,y,sx,sy,w,h,8,8,16,16,l,t,r,bot));
                if(p.w && p.h)jarbox_binary_blit(candidate+p.y*16+p.x,16,pixels+p.sy*8+p.sx,8,p.w,p.h,kind);
            }
            CGImageRelease(crop);
            CGContextFlush(a);CGContextFlush(b);
            assert(!memcmp(candidate,reference,sizeof candidate));
        }
        CGContextRelease(a);CGContextRelease(b);CGImageRelease(image);CGContextRelease(source);
    }
    CGColorSpaceRelease(cs);puts("PASS 16000 CoreGraphics/software ordered draws");
}
