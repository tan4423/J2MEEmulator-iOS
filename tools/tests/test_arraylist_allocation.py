"""Exercise actual ArrayList growth and overflow guards with allocation injection."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
ROOT=Path(__file__).resolve().parents[2]
SOURCE=ROOT/"J2MEEmulator/minijvm/utils/arraylist.c"
PRE=r"""
#include <assert.h>
#include <limits.h>
#include <stdint.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
typedef uint32_t u32;
typedef void *ArrayListValue;
typedef struct {ArrayListValue *data; int length, _alloced, spinlock;} ArrayList;
static int fail,allocs;
static u32 last_size;
static void *jvm_calloc(u32 n){++allocs;last_size=n;return fail?NULL:calloc(1,n);}
static void jvm_free(void *p){free(p);}
static void spin_init(int *l,int shared){(void)shared;*l=0;}
static void spin_destroy(int *l){(void)l;}
"""
MAIN=r"""
int main(void){
    int a=1,b=2,c=3;
    int limit=arraylist_capacity_limit();
    assert((uint64_t)limit*sizeof(void*)<=UINT32_MAX);
    assert(limit<INT_MAX);
    assert(arraylist_create(INT_MAX)==NULL && allocs==0);
    ArrayList *l=arraylist_create(2);assert(l);
    assert(_arraylist_insert_impl(l,0,&a));assert(_arraylist_insert_impl(l,1,&b));
    int oldalloc=allocs;assert(!_arraylist_insert_impl(l,INT_MAX,&c)&&allocs==oldalloc);
    fail=1;assert(!_arraylist_insert_impl(l,1,&c));assert(l->length==2&&l->_alloced==2&&l->data[0]==&a&&l->data[1]==&b);
    fail=0;assert(_arraylist_insert_impl(l,1,&c));assert(l->length==3&&l->_alloced==4&&l->data[1]==&c&&l->data[2]==&b);
    arraylist_remove_range(l,1,INT_MAX);assert(l->length==3);
    arraylist_remove_range(l,1,1);assert(l->length==2&&l->data[1]==&b);
    arraylist_destroy(l);
    ArrayList huge={.length=limit,._alloced=limit};oldalloc=allocs;
    assert(!_arraylist_insert_impl(&huge,limit,&a)&&allocs==oldalloc);
    huge.length=huge._alloced=limit/2+1;fail=1;
    assert(!arraylist_enlarge(&huge));assert(last_size==(u32)((uint64_t)limit*sizeof(void*)));
    assert(huge._alloced==limit/2+1&&huge.data==NULL);
    puts("arraylist size bound, fault retention, invalid range and growth PASS");
}
"""
class ArrayListAllocationTest(unittest.TestCase):
    def test_growth_and_capacity(self):
        cc=shutil.which("cc")
        if not cc:self.skipTest("host compiler unavailable")
        s=SOURCE.read_text()
        a=s.index("static inline int arraylist_capacity_limit(void)")
        b=s.index("int arraylist_insert(ArrayList",a)
        c=s.index("static inline void arraylist_remove_range(")
        d=s.index("\n}",c)+2
        with tempfile.TemporaryDirectory() as td:
            p,exe=Path(td)/"array.c",Path(td)/"array"
            p.write_text(PRE+s[a:b]+s[c:d]+MAIN)
            subprocess.run([cc,"-std=c11","-Wall","-Wextra","-Werror",str(p),"-o",str(exe)],check=True,timeout=30)
            subprocess.run([str(exe)],check=True,timeout=10)
if __name__=="__main__":unittest.main()
