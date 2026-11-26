"""Run production native containers with allocator fault injection.

The fixture uses actual container implementations and tinycthread, with only
the allocation functions replaced. The file loader is extracted from its VM TU.
"""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
ROOT=Path(__file__).resolve().parents[2]
UTIL=ROOT/"J2MEEmulator/minijvm/utils"
VM=UTIL.parent/"jvm/jvm_util.c"
PRE=r"""
#include <assert.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "d_type.h"
static int fail_after=-1, live;
static int reject(void){
    if(fail_after<0)return 0;
    if(!fail_after)return 1;
    --fail_after;return 0;
}
static void *audit_calloc(u32 n){
    if(reject())return NULL;
    void*p=calloc(1,n);if(p)++live;return p;
}
static void *audit_malloc(u32 n){
    if(reject())return NULL;
    void*p=malloc(n);if(p)++live;return p;
}
static void audit_free(void*p){if(p)--live;free(p);}
#define jvm_calloc audit_calloc
#define jvm_malloc audit_malloc
#define jvm_free audit_free
#include "arraylist.c"
#include "hashset.c"
#include "hashtable.c"
#include "bytebuf.c"
static int open_count;
static FILE *audit_fopen(const char *p,const char *m){
    FILE *fp=fopen(p,m);if(fp)++open_count;return fp;
}
static int audit_fclose(FILE *fp){--open_count;return fclose(fp);}
#define fopen audit_fopen
#define fclose audit_fclose
"""
MAIN=r"""
#undef fopen
#undef fclose
static s64 negative_hash(HashtableKey p){return LLONG_MIN+*(int*)p;}
static int key_frees,value_frees;
static void count_key(HashtableKey p){(void)p;++key_frees;}
static void count_value(HashtableValue p){(void)p;++value_frees;}
static void check_buffers(void){
    for(int i=0;i<10000;i++){
        fail_after=0;assert(!bytebuf_create(1)&&live==0);
        fail_after=1;assert(!bytebuf_create(1)&&live==0);
        fail_after=-1;
        ByteBuf *a=bytebuf_create(1),*b=bytebuf_create(1);assert(a&&b);
        assert(bytebuf_write(a,0x81)==1);
        fail_after=0;
        assert(bytebuf_write_long(a,INT64_MIN)==-1&&a->wp==1&&a->_alloc_size==1&&(u8)a->buf[0]==0x81);
        assert(bytebuf_write(b,1)==1);
        assert(bytebuf_read_from(b,a,1)==-1&&a->rp==0&&b->wp==1);
        fail_after=-1;
        assert(bytebuf_write_long(a,INT64_MIN)==8);
        assert(bytebuf_write_int(a,INT32_MIN)==4);
        assert(bytebuf_write_short(a,INT16_MIN)==2);
        assert(bytebuf_read(a)==0x81&&bytebuf_read_long(a)==INT64_MIN&&bytebuf_read_int(a)==INT32_MIN&&bytebuf_read_short(a)==INT16_MIN);
        assert(!bytebuf_hasmore(a,UINT32_MAX)&&bytebuf_read(a)==-1);
        a->rp=0;
        assert(bytebuf_read_from(b,a,15)==15&&a->rp==15&&b->wp==16);
        assert(bytebuf_write_batch(b,b->buf,16)==16&&b->wp==32);
        assert(!memcmp(b->buf,b->buf+16,16));
        u32 cap=b->_alloc_size;bytebuf_expand(b,1);assert(b->_alloc_size==cap&&b->wp==32);
        assert(bytebuf_write_batch(b,NULL,1)==-1&&bytebuf_write_batch(b,NULL,0)==0);
        assert(bytebuf_read_batch(b,NULL,1)==-1);
        assert(bytebuf_write_batch(b,b->buf+31,2)==-1);
        ByteBuf invalid={.rp=UINT32_MAX,.wp=0,.buf=b->buf,._alloc_size=b->_alloc_size};
        assert(!bytebuf_hasmore(&invalid,1)&&bytebuf_write(&invalid,0)==-1);
        bytebuf_destroy(a);bytebuf_destroy(b);assert(live==0);
    }
}
static void check_hashes(void){
    int keys[128];
    for(int i=0;i<128;++i)keys[i]=i;
    for(int failure=0;failure<4;++failure){
        fail_after=failure;assert(!hashset_create()&&live==0);
    }
    fail_after=-1;
    for(int round=0;round<100;++round){
        Hashset *s=hashset_create();assert(s);
        for(int i=0;i<128;++i)assert(hashset_put(s,&keys[i]));
        u64 cap=s->table_size;assert(cap>8);
        fail_after=0;hashset_clear(s);
        assert(!s->entries&&s->table_size==cap);
        assert(!hashset_put(s,&keys[0]));
        fail_after=-1;assert(hashset_put(s,&keys[0]));
        assert(hashset_get(s,&keys[0])==&keys[0]);
        hashset_destroy(s);assert(live==0);
        Hashtable *h=hashtable_create(negative_hash,DEFAULT_HASH_EQUALS_FUNC);assert(h);
        for(int i=0;i<128;++i)assert(hashtable_put(h,&keys[i],&keys[127-i]));
        assert(hashtable_num_entries(h)==128);
        for(int i=0;i<128;++i)assert(hashtable_get(h,&keys[i])==&keys[127-i]);
        s64 sz=h->table_size;
        assert(!hashtable_resize(h,LLONG_MAX)&&h->table_size==sz);
        fail_after=0;assert(!hashtable_resize(h,sz*2)&&h->table_size==sz);
        fail_after=-1;
        for(int i=0;i<128;++i)assert(hashtable_remove(h,&keys[i],0));
        assert(!hashtable_num_entries(h));
        hashtable_register_free_functions(h,count_key,count_value);
        key_frees=value_frees=0;
        assert(hashtable_put(h,&keys[0],&keys[1]));
        assert(hashtable_put(h,&keys[0],&keys[1]));
        assert(!key_frees&&!value_frees);
        assert(hashtable_put(h,&keys[0],&keys[2]));
        assert(!key_frees&&value_frees==1);
        hashtable_destroy(h);assert(key_frees==1&&value_frees==2&&live==0);
    }
}
static void check_file(const char *path,const char *empty){
    for(int i=0;i<1000;++i){
        ByteBuf *b=bytebuf_create(1);assert(b);
        fail_after=0;assert(_loadFileContents(path,b)==-1&&b->wp==0&&open_count==0);
        // One destination growth is sufficient; no temporary file buffer.
        fail_after=1;assert(_loadFileContents(path,b)==0&&b->wp==4&&!memcmp(b->buf,"test",4)&&fail_after==0);
        b->rp=b->wp=0;
        // Existing capacity needs no allocation at all.
        assert(_loadFileContents(path,b)==0&&b->wp==4&&!memcmp(b->buf,"test",4));
        fail_after=-1;
        assert(_loadFileContents(empty,b)==0&&b->wp==4&&open_count==0);
        bytebuf_destroy(b);assert(live==0);
    }
}
int main(int argc,char **argv){
    assert(argc==3);
    check_buffers();check_hashes();check_file(argv[1],argv[2]);
    puts("Native containers and classpath fault-injection: PASS");
    return 0;
}
"""
class NativeContainerAudit(unittest.TestCase):
    def test_actual_container_sources(self):
        cc=shutil.which("cc")
        if not cc:self.skipTest("host C compiler unavailable")
        source=VM.read_text()
        a=source.index("s32 _loadFileContents(c8 const *file, ByteBuf *buf) {")
        b=source.index("\n}",a)+2
        with tempfile.TemporaryDirectory() as tmp:
            p=Path(tmp)
            (p/"input").write_bytes(b"test")
            (p/"empty").write_bytes(b"")
            (p/"audit.c").write_text(PRE+source[a:b]+"\n"+MAIN)
            subprocess.run([cc,"-std=gnu11","-O2","-pthread","-I",str(UTIL),str(p/"audit.c"),str(UTIL/"tinycthread.c"),"-o",str(p/"audit")],check=True,timeout=60)
            subprocess.run([str(p/"audit"),str(p/"input"),str(p/"empty")],check=True,timeout=30)
if __name__=="__main__":unittest.main()
