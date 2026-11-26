"""Host tests compile the production crop cache against reference-counted CG stubs.
No Core Graphics pixel rendering is tested on this host.
"""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT=Path(__file__).resolve().parents[2]
NATIVE=ROOT/"J2MEEmulator/NativeBridge"
CODE=r"""
#include <assert.h>
#include <stdint.h>
#include <stdlib.h>
#include <stddef.h>
typedef struct {int x,y,w,h;} CGRect;
static CGRect CGRectMake(int x,int y,int w,int h){return (CGRect){x,y,w,h};}
typedef struct Fake {size_t stride,height; int refs; struct Fake *parent; CGRect rect;} *CGImageRef;
static unsigned live, creates, fail;
static CGImageRef make(size_t stride,size_t height){
    CGImageRef i=calloc(1,sizeof(*i)); assert(i); i->stride=stride;i->height=height;i->refs=1; ++live;return i;
}
static size_t CGImageGetBytesPerRow(CGImageRef i){return i->stride;}
static size_t CGImageGetHeight(CGImageRef i){return i->height;}
static CGImageRef CGImageRetain(CGImageRef i){assert(i && i->refs>0);++i->refs;return i;}
static void CGImageRelease(CGImageRef i){assert(i && i->refs>0);if (!--i->refs){if(i->parent)CGImageRelease(i->parent);free(i);--live;}}
static CGImageRef CGImageCreateWithImageInRect(CGImageRef i,CGRect r){
    ++creates;if(fail)return NULL;CGImageRef j=make((size_t)r.w*4,(size_t)r.h);
    j->parent=CGImageRetain(i);j->rect=r;return j;
}
#include "jarbox_crop_cache.h"
int main(void){
    JarBoxCropCache a={0}, b={0};int hit;
    CGImageRef src=make(256,64),other=make(256,64);
    CGImageRef first=jarbox_crop_get(&a,src,1,2,8,8,&hit);
    assert(first && !hit && creates==1);
    for(int n=0;n<100000;n++){
        CGImageRef next=jarbox_crop_get(&a,src,1,2,8,8,&hit);
        assert(next==first && hit);CGImageRelease(next);
    }
    assert(creates==1);
    CGImageRef separate=jarbox_crop_get(&b,src,1,2,8,8,&hit);
    assert(separate!=first && !hit);CGImageRelease(separate);
    CGImageRef different=jarbox_crop_get(&a,other,1,2,8,8,&hit);
    assert(different!=first && !hit && different->parent==other);CGImageRelease(different);
    CGImageRelease(first);
    for(int n=0;n<100000;n++){
        int x=n%53,y=(n/53)%53;
        CGImageRef q=jarbox_crop_get(&a,src,x,y,8,8,&hit);
        assert(q && q->parent==src && q->rect.x==x && q->rect.y==y && q->rect.w==8);
        assert(a.bytes+sizeof(a)<=JARBOX_CROP_BUDGET);
        CGImageRelease(q);
    }
    size_t prev=a.bytes;
    fail=1;
    assert(!jarbox_crop_get(&a,src,0,0,3,3,&hit) && !hit && a.bytes==prev);
    fail=0;
    CGImageRef large=make(SIZE_MAX,2);
    CGImageRef q=jarbox_crop_get(&a,large,0,0,2,2,&hit);
    assert(q && !hit && a.bytes==prev);CGImageRelease(q);CGImageRelease(large);
    q=jarbox_crop_get(NULL,src,0,0,2,2,&hit);
    assert(q && !hit);CGImageRelease(q);
    CGImageRelease(src);CGImageRelease(other);
    jarbox_crop_clear(&a);jarbox_crop_clear(&a);assert(!a.bytes && live>0);
    jarbox_crop_clear(&b);assert(!b.bytes && live==0);
}
"""
class CompatiblePaintTest(unittest.TestCase):
    def test_cache(self):
        cc=shutil.which(os.environ.get("CC","cc"))
        if not cc:self.skipTest("C compiler unavailable")
        with tempfile.TemporaryDirectory() as tmp:
            p=Path(tmp);(p/"test.c").write_text(CODE)
            subprocess.run([cc,"-std=c11","-O2","-Wall","-Wextra","-Werror","-I",str(NATIVE),str(p/"test.c"),"-o",str(p/"test")],check=True,timeout=45)
            subprocess.run([str(p/"test")],check=True,timeout=20)
    def test_wiring(self):
        s=(NATIVE/"j2me_render.m").read_text()
        region=s.split("static s32 treo_draw_region(",1)[1].split("\n}",1)[0]
        self.assertIn("afkMode==1 && rc->ownsPixels && rc->clipSaved",region)
        self.assertIn("!img->isMutable && img->immutableSnapshot",region)
        self.assertLess(region.index("treo_live_barrier(rc);"),region.index("const int compatible"))
        self.assertIn("treo_region_outside_clip(rc->regionClipBounds,xDst,yDst,outW,outH)",region)
        self.assertIn("CGImageCreateWithImageInRect(fullImage, CGRectMake(xSrc, ySrc, wSrc, hSrc))",region)
        discard=s.split("static void treo_live_discard(RenderContext *rc) {",1)[1].split("\n}",1)[0]
        self.assertIn("jarbox_crop_clear(rc->cropCache)",discard)
        self.assertIn("native_heap_sub(rc->heap_key",discard)
        self.assertEqual(s.count("treo_live_discard(rc);"),2)
        self.assertIn("return treo_rc_mode(rc) == TreoAFKFastCanvas;",s)
        for name in ("n_setColor","n_setClip","n_setStrokeStyle"):
            f=s.split("static s32 "+name+"(",1)[1].split("\n}",1)[0]
            self.assertIn("rc->ownsPixels && rc->clipSaved && treo_rc_reuse_state(rc)",f)
if __name__=="__main__":unittest.main()
