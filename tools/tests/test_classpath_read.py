"""Production loose-file read and classpath probe reuse, with modeled ZIPs."""
from pathlib import Path
import os
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
CORE = ROOT / "J2MEEmulator/minijvm"
PRE = r"""
#include <assert.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
typedef int32_t s32;
typedef uint32_t u32;
typedef uint64_t u64;
typedef char c8;
typedef struct { u32 _alloc_size,rp,wp; c8 *buf; } ByteBuf;
static int deny, allocations, live, short_read, open_files;
static void *jvm_malloc(u32 n) { ++allocations; if(deny)return NULL; void *p=malloc(n); if(p)++live;return p; }
static void *jvm_calloc(u32 n) { void *p=jvm_malloc(n);if(p)memset(p,0,n);return p; }
static void jvm_free(void *p) { if(p)--live;free(p); }
static FILE *audit_open(const char *p,const char *m){FILE *f=fopen(p,m);if(f)++open_files;return f;}
static int audit_close(FILE *f){--open_files;return fclose(f);}
static size_t audit_read(void *p,size_t size,size_t n,FILE *f){return fread(p,size,short_read&&n?n-1:n,f);}
#define fopen audit_open
#define fclose audit_close
#define fread audit_read
typedef struct { char text[1024]; } Utf8String;
typedef struct { Utf8String *items[4]; int length; } ArrayList;
typedef struct { uint64_t shared_zip_probes,shared_zip_hits,shared_zip_negative_hits,shared_zip_hit_bytes; } JarBoxSession;
typedef struct { JarBoxSession *session; } MiniJVM;
typedef struct { MiniJVM *jvm; ArrayList *classpath; } PeerClassLoader;
static int zip_calls;
static Utf8String *arraylist_get_value(ArrayList *a,int i){return a->items[i];}
static int isDir(Utf8String *u){return u->text[0]=='/';}
static Utf8String *utf8_create_copy(Utf8String *u){Utf8String *p=malloc(sizeof(*p));assert(p);*p=*u;return p;}
static int utf8_pushback(Utf8String *u,char c){size_t n=strlen(u->text);assert(n+1<sizeof(u->text));u->text[n]=c;u->text[n+1]=0;return 1;}
static void utf8_append(Utf8String *u,Utf8String *v){assert(strlen(u->text)+strlen(v->text)<sizeof(u->text));strcat(u->text,v->text);}
static const char *utf8_cstr(Utf8String *u){return u->text;}
static void utf8_destroy(Utf8String *u){free(u);}
static s32 zip_classpath_loadfile_profiled(const char *jar,const char *name,ByteBuf *b,int *hit){
    assert(!b->wp&&!b->rp&&!strcmp(name,"payload"));++zip_calls;
    if(!strcmp(jar,"miss")){*hit=2;memcpy(b->buf,"stale",5);b->wp=5;b->rp=1;return -1;}
    assert(!strcmp(jar,"hit"));*hit=1;memcpy(b->buf,"ZIP",3);b->wp=3;return 0;
}
"""
MAIN = r"""
int main(int argc,char **argv){
    assert(argc==4);
    Utf8String miss={"miss"},hit={"hit"},dir={0},name={"payload"};
    assert(strlen(argv[1])<sizeof(dir.text));strcpy(dir.text,argv[1]);
    JarBoxSession session={0},other={0};MiniJVM j={&session};
    ArrayList paths={{&miss,&miss,&hit,&dir},4};PeerClassLoader loader={&j,&paths};
    for(int round=0;round<1000;++round){
        ByteBuf *b=bytebuf_create(4);assert(b);b->buf[0]='A';b->buf[1]='B';b->rp=1;b->wp=2;
        int before=allocations;deny=1;
        assert(_loadFileContents(argv[2],b)==-1&&allocations==before+1);
        assert(b->rp==1&&b->wp==2&&b->_alloc_size==4&&!memcmp(b->buf,"AB",2));
        deny=0;short_read=1;
        assert(_loadFileContents(argv[2],b)==-1&&allocations==before+2);
        assert(b->rp==1&&b->wp==2&&!memcmp(b->buf,"AB",2)&&!open_files);
        short_read=0;before=allocations;
        assert(_loadFileContents(argv[2],b)==0&&allocations==before);
        assert(b->rp==1&&b->wp==66&&!memcmp(b->buf,"AB",2));
        for(unsigned i=2;i<66;++i)assert(b->buf[i]=='x');
        assert(_loadFileContents(argv[3],b)==0&&b->wp==66);
        assert(_loadFileContents("/nonexistent-jarbox-file",b)==-1&&b->wp==66);
        ByteBuf invalid={4,3,2,b->buf};assert(_loadFileContents(argv[2],&invalid)==-1);
        ByteBuf huge={UINT32_MAX,0,UINT32_MAX-1,b->buf};assert(_loadFileContents(argv[2],&huge)==-1);
        bytebuf_destroy(b);assert(!live&&!open_files);
        before=allocations;zip_calls=0;
        b=load_file_from_classpath(&loader,&name);
        assert(b&&b->wp==3&&b->rp==0&&!memcmp(b->buf,"ZIP",3)&&zip_calls==3);
        assert(allocations==before+2);bytebuf_destroy(b);assert(!live);
        paths.items[2]=&dir;paths.length=3;before=allocations;zip_calls=0;
        b=load_file_from_classpath(&loader,&name);
        assert(b&&b->wp==64&&b->rp==0&&b->buf[0]=='x'&&zip_calls==2);
        assert(allocations==before+3);bytebuf_destroy(b);assert(!live&&!open_files);
        paths.length=2;before=allocations;
        assert(!load_file_from_classpath(&loader,&name)&&allocations==before+2&&!live);
        deny=1;before=allocations;zip_calls=0;
        assert(!load_file_from_classpath(&loader,&name)&&allocations==before+1&&!zip_calls&&!live);
        deny=0;paths.items[2]=&hit;paths.length=4;
    }
    assert(session.shared_zip_probes==7000&&session.shared_zip_hits==1000);
    assert(session.shared_zip_negative_hits==6000&&session.shared_zip_hit_bytes==3000);
    assert(!other.shared_zip_probes&&!other.shared_zip_hits);
    puts("1000 classpath and file fault-injection batches PASS");
}
"""


def extract(source, signature):
    start = source.index(signature)
    return source[start:source.index("\n}", start) + 2]


class ClasspathReadTest(unittest.TestCase):
    def test_production_read_and_probe_reuse(self):
        cc = shutil.which(os.environ.get("CC", "cc"))
        if not cc:
            self.skipTest("host compiler unavailable")
        util = (CORE / "jvm/jvm_util.c").read_text()
        buf = (CORE / "utils/bytebuf.c").read_text()
        source = PRE + "\n".join(extract(buf, x) for x in (
            "ByteBuf *bytebuf_create(", "void bytebuf_destroy(",
            "static int bytebuf_valid(", "void bytebuf_expand("))
        source += "\n" + "\n".join(extract(util, x) for x in (
            "s32 _loadFileContents(", "ByteBuf *load_file_from_classpath(")) + MAIN
        flags = ["-std=c11", "-O2", "-Wall", "-Wextra", "-Werror"]
        if os.environ.get("JARBOX_CLASSPATH_SANITIZE") == "1":
            flags += ["-g", "-O1", "-fsanitize=address,undefined", "-fno-omit-frame-pointer"]
        with tempfile.TemporaryDirectory() as td:
            p = Path(td)
            (p / "payload").write_bytes(b"x" * 64)
            (p / "empty").write_bytes(b"")
            (p / "test.c").write_text(source)
            subprocess.run([cc, *flags, str(p / "test.c"), "-o", str(p / "test")], check=True, timeout=30)
            run = subprocess.run([str(p / "test"), str(p), str(p / "payload"), str(p / "empty")],
                                 capture_output=True, text=True, timeout=20)
            self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
            self.assertIn("1000 classpath and file fault-injection batches PASS", run.stdout)


if __name__ == "__main__":
    unittest.main()
