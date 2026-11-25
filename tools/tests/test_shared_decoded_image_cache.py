"""Exercise cache retain/release policy and RGB bounds with portable C doubles.

CoreGraphics itself requires iOS/macOS; these tests compile exact cache logic,
not a native pixel equivalence or device performance benchmark.
"""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT=Path(__file__).resolve().parents[2]
RENDER=ROOT/"J2MEEmulator/NativeBridge/j2me_render.m"
PRE=r"""
#include <stdint.h>
#include <stddef.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <pthread.h>
#include <stdatomic.h>
typedef unsigned char UInt8;
typedef long CFIndex;
typedef struct Obj {int refs; size_t n; unsigned char data[];} Obj;
typedef Obj *CFDataRef;
typedef Obj *CGImageRef;
typedef Obj *CGContextRef;
static int objects;
static CFDataRef CFDataCreate(void *alloc,const UInt8 *p,CFIndex n){
 (void)alloc;Obj *o=malloc(sizeof(*o)+(size_t)n);if(!o)return NULL;
 o->refs=1;o->n=(size_t)n;if(n)memcpy(o->data,p,(size_t)n);objects++;return o;
}
static CFDataRef CFRetain(Obj *o){++o->refs;return o;}
static void CFRelease(Obj *o){if(!--o->refs){objects--;free(o);}}
static CFIndex CFDataGetLength(CFDataRef o){return (CFIndex)o->n;}
static const UInt8 *CFDataGetBytePtr(CFDataRef o){return o->data;}
static int CFEqual(CFDataRef a,CFDataRef b){return a->n==b->n&&!memcmp(a->data,b->data,a->n);}
static CGImageRef CGImageRetain(CGImageRef o){return CFRetain(o);}
static void CGImageRelease(CGImageRef o){CFRelease(o);}
static void CGContextRelease(CGContextRef o){CFRelease(o);}
typedef struct {CGContextRef ctx;CGImageRef immutableSnapshot;CFDataRef immutablePixels;
 int width,height,isMutable;const uint32_t *softwareSource;size_t softwareStride;} RenderImage;
"""
MAIN=r"""
#define CHECK(x) do{if(!(x)){fprintf(stderr,"failure %d\n",__LINE__);return 1;}}while(0)
static RenderImage image(unsigned value) {
 uint32_t p[4]={value,2,3,4};
 RenderImage i={0};i.width=i.height=2;i.softwareStride=2;
 i.ctx=CFDataCreate(NULL,(const UInt8 *)p,sizeof(p));
 i.immutableSnapshot=CFDataCreate(NULL,(const UInt8 *)p,sizeof(p));
 i.softwareSource=(const uint32_t *)CFDataGetBytePtr(i.ctx);return i;
}
static void drop(RenderImage *i) {
 if(i->ctx)CGContextRelease(i->ctx);
 if(i->immutablePixels)CFRelease(i->immutablePixels);
 if(i->immutableSnapshot)CGImageRelease(i->immutableSnapshot);
}
int main(void){
 CFDataRef k=CFDataCreate(NULL,(const UInt8 *)"abc",3);
 CFDataRef other=CFDataCreate(NULL,(const UInt8 *)"abd",3);
 RenderImage a=image(123),b={0};
 unsigned epoch=atomic_load(&jarbox_decoded_epoch);
 uint64_t hash=jarbox_decoded_hash(k);
 jarbox_decoded_publish(&a,k,hash,epoch);
 CHECK(!a.ctx&&a.immutablePixels&&a.softwareSource[0]==123);
 CHECK(jarbox_decoded_lookup(&b,k,hash));
 CHECK(!b.ctx&&b.softwareSource==a.softwareSource&&b.immutableSnapshot==a.immutableSnapshot);
 CHECK(!jarbox_decoded_lookup(&(RenderImage){0},other,hash)); // forced collision
 CHECK(jarbox_decoded_used<=JARBOX_DECODED_BUDGET);
 jarbox_decoded_clear_locked();CHECK(!jarbox_decoded_used);
 drop(&a);CHECK(b.softwareSource[0]==123);drop(&b);
 RenderImage late=image(999);atomic_fetch_add(&jarbox_decoded_epoch,1);
 jarbox_decoded_publish(&late,k,hash,epoch);CHECK(late.ctx&&!late.immutablePixels);drop(&late);
 RenderImage mutable=image(1);mutable.isMutable=1;
 jarbox_decoded_publish(&mutable,k,hash,atomic_load(&jarbox_decoded_epoch));
 CHECK(mutable.ctx&&!mutable.immutablePixels);drop(&mutable);
 for(unsigned n=0;n<JARBOX_DECODED_SLOTS+10;n++){
   CFDataRef item=CFDataCreate(NULL,(const UInt8 *)&n,sizeof(n));RenderImage i=image(n);
   jarbox_decoded_publish(&i,item,jarbox_decoded_hash(item),atomic_load(&jarbox_decoded_epoch));
   CHECK(jarbox_decoded_used<=JARBOX_DECODED_BUDGET);drop(&i);CFRelease(item);
 }
 jarbox_decoded_clear_locked();
 // Fill the byte budget before the slot limit. New entries must evict LRU.
 for(unsigned n=0;n<8;n++){
   CFDataRef item=CFDataCreate(NULL,(const UInt8 *)&n,sizeof(n));
   size_t bytes=JARBOX_DECODED_MAX_PIXELS;
   UInt8 *large=calloc(1,bytes);CHECK(large);
   RenderImage i={0};i.width=256;i.height=512;i.softwareStride=256;
   i.ctx=CFDataCreate(NULL,large,(CFIndex)bytes);
   i.immutableSnapshot=CFDataCreate(NULL,large,(CFIndex)bytes);
   i.softwareSource=(const uint32_t*)CFDataGetBytePtr(i.ctx);free(large);
   jarbox_decoded_publish(&i,item,jarbox_decoded_hash(item),atomic_load(&jarbox_decoded_epoch));
   CHECK(i.immutablePixels&&jarbox_decoded_used<=JARBOX_DECODED_BUDGET);
   drop(&i);CFRelease(item);
 }
 unsigned oldest=0,newest=7;
 CFDataRef oldKey=CFDataCreate(NULL,(const UInt8 *)&oldest,sizeof(oldest));
 CFDataRef newKey=CFDataCreate(NULL,(const UInt8 *)&newest,sizeof(newest));
 RenderImage last={0};
 CHECK(!jarbox_decoded_lookup(&last,oldKey,jarbox_decoded_hash(oldKey)));
 CHECK(jarbox_decoded_lookup(&last,newKey,jarbox_decoded_hash(newKey)));
 pthread_mutex_lock(&jarbox_decoded_lock);
 CHECK(!jarbox_decoded_lookup(&(RenderImage){0},newKey,jarbox_decoded_hash(newKey)));
 pthread_mutex_unlock(&jarbox_decoded_lock);
 jarbox_decoded_clear_locked();drop(&last);
 CFRelease(oldKey);CFRelease(newKey);CFRelease(k);CFRelease(other);CHECK(objects==0);
 CHECK(jarbox_image_rgb_range(3,3,9,6,-3,0,0,3,3));
 CHECK(jarbox_image_rgb_range(3,3,9,0,3,0,0,3,3));
 CHECK(!jarbox_image_rgb_range(3,3,8,0,3,0,0,3,3));
 CHECK(!jarbox_image_rgb_range(3,3,9,5,-3,0,0,3,3));
 CHECK(!jarbox_image_rgb_range(3,3,9,0,2,0,0,3,3));
 CHECK(!jarbox_image_rgb_range(3,3,9,0,3,2147483647,0,3,3));
 return 0;
}
"""
class SharedDecodedImageCacheTest(unittest.TestCase):
    def test_cache_ownership_collision_trim_and_bounds(self):
        cc=shutil.which("cc")
        if not cc:self.skipTest("C compiler unavailable")
        src=RENDER.read_text()
        a=src.index("/* JARBOX_DECODED_CACHE_BEGIN")
        b=src.index("/* JARBOX_DECODED_CACHE_END",a)
        c=src.index("static int jarbox_image_rgb_range(")
        d=src.index("static s32 n_getImageRGB",c)
        with tempfile.TemporaryDirectory() as td:
            p=Path(td)/"cache.c";exe=Path(td)/"cache"
            p.write_text(PRE+src[a:b]+src[c:d]+MAIN)
            subprocess.run([cc,"-std=c11","-Wall","-Wextra","-Werror","-pthread",str(p),"-o",str(exe)],check=True,timeout=30)
            subprocess.run([str(exe)],check=True,timeout=10)

    def test_native_handle_and_pressure_integration(self):
        s=RENDER.read_text()
        self.assertIn("img->heap_key = owner_key;",s)
        self.assertIn("jarbox_decoded_trim();",s.split("int j2me_render_trim_memory_cache(void)",1)[1].split("\n}",1)[0])
        self.assertIn("if (img && img->isMutable && img->ctx)",s)
        self.assertGreaterEqual(s.count("if (img->immutablePixels) CFRelease(img->immutablePixels);"),3)
        self.assertIn("startup_image_hits",s)
        self.assertIn("arr->mb.arr_type_index != DATATYPE_INT",s)

if __name__=="__main__":
    unittest.main()
