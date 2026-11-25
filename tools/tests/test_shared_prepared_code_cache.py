"""Host tests for immutable prepared code templates, not a full JVM execution."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
JVM = ROOT / "J2MEEmulator/minijvm/jvm"

C = r"""
#include <stdint.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
typedef int32_t s32;
typedef uint8_t u8;
typedef struct { intptr_t leftl, rightl; } Pair;
typedef struct { Pair *ptr; s32 count, _alloced; } Pairlist;
static int fail_alloc;
static Pairlist *pairlist_create(s32 count) { if(fail_alloc) return NULL; Pairlist *p=calloc(1,sizeof(*p)); if(!p)return NULL; p->ptr=calloc((size_t)count,sizeof(Pair)); if(!p->ptr){free(p);return NULL;} p->_alloced=count; return p; }
static void pairlist_destroy(Pairlist *p) {free(p->ptr);free(p);}
typedef struct {u8 *code,*bytecode_for_jit; s32 code_length;} CodeAttribute;
typedef struct {Pairlist *pos_2_label; CodeAttribute *converted_code;} MethodInfo;
#include "jarbox_prepared_code_cache.h"
#define CHECK(c) do {if(!(c)){fprintf(stderr,"failed line %d\n",__LINE__);return 1;}}while(0)
int main(void) {
    u8 raw[256], converted[256], dest[256], other[256];
    memset(raw, 3, sizeof(raw)); memset(converted, 5, sizeof(converted));
    CodeAttribute a={converted,raw,256}, b={dest,other,256};
    MethodInfo ma={pairlist_create(10),&a}, mb={pairlist_create(4),&b};
    CHECK(ma.pos_2_label && mb.pos_2_label);
    ma.pos_2_label->count=10;
    for(int i=0;i<10;i++){ma.pos_2_label->ptr[i].leftl=i*2;ma.pos_2_label->ptr[i].rightl=-1;}
    uint64_t h=jarbox_prepared_hash(raw,256); unsigned epoch=atomic_load(&jarbox_prepared_epoch);
    CHECK(h && !jarbox_prepared_hash(raw,127));
    memcpy(dest,raw,256); CHECK(!jarbox_prepared_lookup(&mb,h,epoch));
    jarbox_prepared_publish(&ma,h,epoch); CHECK(jarbox_prepared_count==1);
    jarbox_prepared_publish(&ma,h,epoch); CHECK(jarbox_prepared_count==1);
    fail_alloc=1; CHECK(!jarbox_prepared_lookup(&mb,h,epoch)); CHECK(!memcmp(dest,raw,256)); fail_alloc=0;
    dest[1]^=1; CHECK(!jarbox_prepared_lookup(&mb,h,epoch)); dest[1]^=1;
    CHECK(jarbox_prepared_lookup(&mb,h,epoch)); CHECK(!memcmp(dest,converted,256));
    CHECK(mb.pos_2_label->count==10 && mb.pos_2_label->ptr[9].leftl==18 && mb.pos_2_label->ptr[9].rightl==-1);
    dest[0]=9; mb.pos_2_label->ptr[0].rightl=123; memcpy(dest,raw,256);
    CHECK(jarbox_prepared_lookup(&mb,h,epoch)); CHECK(dest[0]==5 && mb.pos_2_label->ptr[0].rightl==-1);
    pthread_mutex_lock(&jarbox_prepared_lock); CHECK(!jarbox_prepared_lookup(&mb,h,epoch)); pthread_mutex_unlock(&jarbox_prepared_lock);
    jarbox_prepared_trim(); CHECK(!jarbox_prepared_bytes && !jarbox_prepared_count && dest[0]==5);
    jarbox_prepared_publish(&ma,h,epoch); CHECK(!jarbox_prepared_count); epoch=atomic_load(&jarbox_prepared_epoch);
    for(unsigned i=0;i<3000;i++){memcpy(raw,&i,sizeof(i)); h=jarbox_prepared_hash(raw,256);jarbox_prepared_publish(&ma,h,epoch);CHECK(jarbox_prepared_count<=JARBOX_PREPARED_MAX_COUNT && jarbox_prepared_bytes<=JARBOX_PREPARED_BUDGET);}
    CHECK(jarbox_prepared_count==JARBOX_PREPARED_MAX_COUNT); jarbox_prepared_trim(); CHECK(!jarbox_prepared_count && !jarbox_prepared_bytes);
    pairlist_destroy(ma.pos_2_label);pairlist_destroy(mb.pos_2_label);puts("prepared cache: PASS");return 0;
}
"""

class PreparedCodeCacheTest(unittest.TestCase):
    def test_production_cache_ownership_and_budget(self):
        cc = shutil.which("cc")
        if not cc:
            self.skipTest("host compiler unavailable")
        with tempfile.TemporaryDirectory() as td:
            c, exe = Path(td)/"cache.c", Path(td)/"cache"
            c.write_text(C)
            subprocess.run([cc, "-std=c11", "-Wall", "-Wextra", "-Werror", "-pthread",
                            "-I", str(JVM), str(c), "-o", str(exe)], check=True, timeout=30)
            subprocess.run([str(exe)], check=True, timeout=10)

    def test_loader_and_pressure_wiring(self):
        s = (JVM/"class_load.c").read_text()
        body = s.split("void _changeBytesOrder(MethodInfo *method) {", 1)[1].split("s32 _convert_to_code_attribute(", 1)[0]
        self.assertLess(body.index("jarbox_prepared_lookup("), body.index("while (ip < end)"))
        self.assertLess(body.index("jarbox_prepared_publish("), body.index("prepared_finish:"))
        self.assertIn("memcpy(ca->bytecode_for_jit, ca->code, ca->code_length);", body)
        self.assertEqual(body.count("preparation_complete = 0;"), 12)
        self.assertIn("preparation_complete && ip == end", body)
        bridge = (ROOT/"J2MEEmulator/NativeBridge/jvm_bridge.c").read_text()
        self.assertIn("jarbox_prepared_code_cache_trim();", bridge.split("void jvm_bridge_trim_classpath_cache(void)", 1)[1].split("}", 1)[0])

    def test_shared_profile_scope_and_logging(self):
        s = (JVM/"class_load.c").read_text()
        parse = s.split("JClass *class_parse(", 1)[1].split("JClass *load_class(", 1)[0]
        self.assertIn("static _Thread_local JarBoxPreparedProfile *jarbox_prepared_profile;", s)
        self.assertLess(parse.index("jarbox_prepared_profile = jvm->session ? &profile : NULL"), parse.index("->_load_class_from_bytes("))
        self.assertLess(parse.index("->_load_class_from_bytes("), parse.index("jarbox_prepared_profile = previous_profile"))
        self.assertIn("&jvm->session->shared_prepared_hits, profile.hits", parse)
        bridge = (ROOT/"J2MEEmulator/NativeBridge/j2me_input.c").read_text()
        for field in ("zip_probes", "zip_hits", "zip_negative_hits", "zip_hit_bytes",
                      "prepared_candidates", "prepared_hits", "prepared_hit_bytes"):
            self.assertIn("shared_" + field, (JVM/"jarbox_session.h").read_text())
            self.assertIn("&session->shared_" + field, bridge)
        self.assertEqual(bridge.count("startup_shared:phase="), 1)

if __name__ == "__main__":
    unittest.main()
