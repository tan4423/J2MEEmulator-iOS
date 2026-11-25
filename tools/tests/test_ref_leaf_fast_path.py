"""Static reference leaf shape and runtime guard regression."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
ROOT=Path(__file__).resolve().parents[2]
JVM=ROOT/"J2MEEmulator/minijvm/jvm"
C=r"""
#include <stdio.h>
#include "jarbox_ref_leaf.h"
#define CHECK(x) do {if(!(x)){fprintf(stderr,"line %d\n",__LINE__);return 1;}}while(0)
int main(void){
    uint8_t a[]={0xb2,0,53,0xc7,0,13,0xbb,0,24,0x59,0xb7,0,79,0xb3,0,53,0xb2,0,53,0xb0};
    uint8_t b[]={0xb2,0,32,0xc7,0,15,0xbb,0,7,0x59,0xb7,0,52,0x59,0xb3,0,32,0xb0,0xb2,0,32,0xb0};
    uint8_t c[]={0xb2,0,44,0xc7,0,17,0xbb,0,2,0x59,0xb7,0,45,0x59,0xb3,0,44,0xa7,0,6,0xb2,0,44,0xb0};
    uint8_t d[]={0xb2,1,2,0xb0};
    CHECK(jarbox_ref_leaf_match(d,4,"()Ljava/lang/Object;",0,1,0)==258);
    CHECK(jarbox_ref_leaf_match(d,4,"()[I",0,1,0)==258);
    uint8_t *v[]={a,b,c};int lengths[]={20,22,24};
    for(int i=0;i<3;i++){
        uint8_t *p=v[i];int n=lengths[i];uint32_t expected=0x10000u|p[2];
        CHECK(jarbox_ref_leaf_match(p,n,"()Lx;",0,2,0)==expected);
        CHECK(!jarbox_ref_leaf_match(p,n,"()I",0,2,0));
        CHECK(!jarbox_ref_leaf_match(p,n,"(I)Lx;",0,2,0));
        CHECK(!jarbox_ref_leaf_match(p,n,"()Lx;",1,2,0));
        CHECK(!jarbox_ref_leaf_match(p,n,"()Lx;",0,1,0));
        CHECK(!jarbox_ref_leaf_match(p,n,"()Lx;",0,2,1));
        for(int j=0;j<n;j++){
            if(j==7||j==8||j==11||j==12)continue;
            p[j]^=1;CHECK(!jarbox_ref_leaf_match(p,n,"()Lx;",0,2,0));p[j]^=1;
        }
        for(int j=0;j<n;j++)CHECK(!jarbox_ref_leaf_match(p,j,"()Lx;",0,2,0));
    }
    return 0;
}
"""
class RefLeafTest(unittest.TestCase):
    def test_shape(self):
        cc=shutil.which("cc")
        if not cc:self.skipTest("host compiler unavailable")
        with tempfile.TemporaryDirectory() as td:
            p,exe=Path(td)/"test.c",Path(td)/"test"
            p.write_text(C)
            subprocess.run([cc,"-std=c11","-Wall","-Wextra","-Werror","-I",str(JVM),str(p),"-o",str(exe)],check=True,timeout=30)
            subprocess.run([str(exe)],check=True,timeout=10)
    def test_runtime_guards(self):
        s=(JVM/"interpreter.c").read_text()
        body=s.split("static inline int jarbox_try_ref_leaf(",1)[1].split("\n}\n",1)[0]
        for guard in ("cp >= cl->constant_item_count","item->tag != CONSTANT_FIELD_REF",
                      "fi->_this_class != cl","ACC_STATIC","fi->isvolatile","ACC_VOLATILE",
                      "field_static_len","_Alignof(__refer)","ca->max_stack > stack->max_size - used",
                      "if (!value) return 0;","push_ref(stack, value);"):
            self.assertIn(guard,body)
        self.assertEqual(body.count("__atomic_load_n((__refer *)address, __ATOMIC_RELAXED)"),2)
        self.assertIn("!treo_game_jit_is_enabled() && jarbox_try_ref_leaf(method, pruntime)",s)
        self.assertIn("jarbox_ref_leaf_pending == 64",s)
        cl=(JVM/"class_load.c").read_text()
        self.assertIn("ptr->treo_ref_leaf = jarbox_ref_leaf_match(",cl)
if __name__=="__main__":unittest.main()
