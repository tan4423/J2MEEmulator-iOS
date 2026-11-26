"""Production compression wrappers: miniz, ByteBuf and injected growth failure."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
import zipfile
import gzip

ROOT=Path(__file__).resolve().parents[2]
UTIL=ROOT/"J2MEEmulator/minijvm/utils"
PRE=r"""
#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "miniz.h"
#include "d_type.h"
static int fail_growth;
static void *audit_malloc(u32 n){return fail_growth ? NULL : malloc(n);}
#define jvm_malloc audit_malloc
#include "bytebuf.c"
#undef jvm_malloc
"""
MAIN=r"""
static char *read_file(const char *path,int *size){
    FILE *f=fopen(path,"rb");assert(f);
    assert(!fseek(f,0,SEEK_END));*size=(int)ftell(f);assert(*size>0);
    rewind(f);char *p=malloc(*size);assert(p);
    assert(fread(p,1,*size,f)==(size_t)*size);fclose(f);return p;
}
int main(int argc,char **argv){
    assert(argc==3);
    int zs,gs;
    char *zip=read_file(argv[1],&zs),*gzip=read_file(argv[2],&gs);
    for(int i=0;i<100;++i){
        ByteBuf *b=bytebuf_create(1);assert(b&&bytebuf_write(b,42)==1);
        fail_growth=1;
        assert(zip_extract(zip,zs,b)==-1 && b->wp==1 && b->buf[0]==42);
        assert(gzip_extract(gzip,gs,b)==-1 && b->wp==1 && b->buf[0]==42);
        assert(gzip_compress("abcd",4,b)==-1 && b->wp==1);
        fail_growth=0;
        assert(zip_extract(zip,zs,b)==0 && b->rp==0 && b->wp==1024);
        for(unsigned k=0;k<b->wp;++k)assert(b->buf[k]=='x');
        b->wp=b->rp=0;
        assert(gzip_extract(gzip,gs,b)==0 && b->wp==1024);
        for(unsigned k=0;k<b->wp;++k)assert(b->buf[k]=='x');
        b->wp=b->rp=0;
        assert(gzip_compress("abcd",4,b)==0);
        ByteBuf *out=bytebuf_create(1);assert(out);
        assert(gzip_extract(b->buf,(int)b->wp,out)==0 && out->wp==4 && !memcmp(out->buf,"abcd",4));
        assert(zip_extract(NULL,0,out)==-1);
        assert(gzip_extract(NULL,20,out)==-1);
        assert(gzip_compress("a",-1,out)==-1);
        assert(zip_compress("a",-1,out)==-1);
        bytebuf_destroy(out);bytebuf_destroy(b);
    }
    free(zip);free(gzip);
    puts("compression growth failure and round trip: PASS");
}
"""
class CompressionAllocationTest(unittest.TestCase):
    def test_actual_miniz_wrappers(self):
        cc=shutil.which("cc")
        if not cc:self.skipTest("host C compiler unavailable")
        s=(UTIL/"miniz_wrapper.c").read_text()
        a=s.index("s32 zip_extract(")
        b=s.index("//void test_gzip_compression",a)
        with tempfile.TemporaryDirectory() as tmp:
            p=Path(tmp)
            with zipfile.ZipFile(p/"input.zip","w",zipfile.ZIP_DEFLATED) as z:z.writestr("data",b"x"*1024)
            (p/"input.gz").write_bytes(gzip.compress(b"x"*1024))
            (p/"test.c").write_text(PRE+s[a:b]+MAIN)
            subprocess.run([cc,"-std=gnu11","-O2","-I",str(UTIL),str(p/"test.c"),str(UTIL/"miniz.c"),"-o",str(p/"test")],check=True,timeout=60)
            subprocess.run([str(p/"test"),str(p/"input.zip"),str(p/"input.gz")],check=True,timeout=20)
if __name__=="__main__":unittest.main()
