"""Use production UTF-8 implementation with injected allocation failure."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT=Path(__file__).resolve().parents[2]
UTIL=ROOT/"J2MEEmulator/minijvm/utils"
C=r"""
#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "d_type.h"
static int deny, allocations;
static void *mock_malloc(u32 n){++allocations;return deny?NULL:malloc(n);}
#define jvm_malloc mock_malloc
#include "utf8_string.c"
int main(void) {
    for(int i=0;i<10000;++i) {
        Utf8String *a=utf8_create_c("java.lang.String");
        Utf8String *b=utf8_create_c("java/lang/String");
        assert(a&&b);
        unsigned long old=_utf8_hashCode(a);
        assert(old);
        int n=allocations;
        utf8_replace_c(a,".","/");
        assert(allocations==n && utf8_equals(a,b));
        utf8_replace_c(a,"/","/");
        assert(allocations==n && utf8_equals(a,b));
        utf8_append_c(a,".class");
        assert(utf8_equals_c(a,"java/lang/String.class"));
        assert(!utf8_equals(a,b));
        unsigned long hash=_utf8_hashCode(a);
        utf8_append_part(a,a,0,a->length);
        assert(utf8_equals_c(a,"java/lang/String.classjava/lang/String.class"));
        assert(_utf8_hashCode(a)!=hash);
        n=a->length;
        deny=1;
        utf8_append_part(a,a,0,n);
        assert(a->length==n);
        deny=0;
        utf8_append_part(a,a,-1,1);
        utf8_append_part(a,a,1,INT_MAX);
        assert(a->length==n);
        utf8_clear(b);
        const char raw[]={0, (char)0x81, (char)0xff, '.'};
        utf8_append_data(b,raw,4);
        assert(b->length==4 && !memcmp(b->data,raw,4));
        utf8_replace_c(b,".","/");
        assert(b->length==4 && b->data[3]=='/');
        utf8_destroy(a);utf8_destroy(b);
    }
    puts("10000 UTF-8 growth, alias, normalization and equality cycles PASS");
}
"""
class Utf8HotPathTest(unittest.TestCase):
    def test_native(self):
        cc=shutil.which("cc")
        if not cc:self.skipTest("C compiler unavailable")
        with tempfile.TemporaryDirectory() as d:
            p=Path(d)
            (p/"test.c").write_text(C)
            subprocess.run([cc,"-std=gnu11","-O2","-I",str(UTIL),str(p/"test.c"),"-o",str(p/"test")],check=True,timeout=60)
            subprocess.run([str(p/"test")],check=True,timeout=20)
if __name__=="__main__":unittest.main()
