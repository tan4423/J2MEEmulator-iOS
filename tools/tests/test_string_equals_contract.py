"""Host fixtures for exact String equality and version-gate helpers."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
CORE = ROOT / "J2MEEmulator/minijvm/jvm"
STRING_STUB = r"""
#include <stdint.h>
#include <string.h>
typedef int32_t s32;
typedef uint16_t u16;
typedef struct { const char *name; } JClass;
typedef struct { JClass *clazz; } Block;
typedef struct Instance {
    Block mb;
    struct Instance *value;
    s32 count, offset, arr_length, arr_type_index;
    void *arr_body;
} Instance;
typedef struct { int unused; } Runtime;
#define STR_CLASS_JAVA_LANG_STRING "java/lang/String"
#define DATATYPE_JCHAR 5
static int utf8_equals_c(const char *a,const char *b){return strcmp(a,b)==0;}
static Instance *jstring_get_value_array(Instance *s,Runtime *rt){(void)rt;return s->value;}
static s32 jstring_get_count(Instance *s,Runtime *rt){(void)rt;return s->count;}
static s32 jstring_get_offset(Instance *s,Runtime *rt){(void)rt;return s->offset;}
"""
STRING_MAIN = r"""
int main(void){
    Runtime rt={0};
    JClass str={"java/lang/String"}, other={"java/lang/Object"};
    u16 a[]={99,65,0,66,99}, b[]={65,0,66};
    Instance av={.arr_length=5,.arr_type_index=5,.arr_body=a};
    Instance bv={.arr_length=3,.arr_type_index=5,.arr_body=b};
    Instance x={.mb={&str},.value=&av,.count=3,.offset=1};
    Instance y={.mb={&str},.value=&bv,.count=3};
    Instance z={.mb={&other}};
    if(!jstring_equals(&x,&y,&rt))return 1;
    if(jstring_equals(&x,&z,&rt)||jstring_equals(&x,0,&rt))return 2;
    if(!jstring_equals(&x,&x,&rt))return 3;
    b[2]=67;if(jstring_equals(&x,&y,&rt))return 4;b[2]=66;
    y.offset=1;if(jstring_equals(&x,&y,&rt))return 5;y.offset=0;
    bv.arr_type_index=8;if(jstring_equals(&x,&y,&rt))return 6;bv.arr_type_index=5;
    y.count=-1;if(jstring_equals(&x,&y,&rt))return 7;
    y.count=0;x.count=0;if(!jstring_equals(&x,&y,&rt))return 8;
    return 0;
}
"""
GATE_STUB = r"""
#include <stdint.h>
#include <string.h>
typedef uint8_t u8;
typedef uint16_t u16;
typedef int16_t s16;
typedef int64_t s64;
enum {op_getstatic=1,op_getstatic_byte,op_putstatic,op_putstatic_byte,
op_invokevirtual,op_invokevirtual_fast,op_aconst_null,op_putstatic_ref,
op_aload,op_invokestatic,op_invokestatic_fast};
typedef struct { int dummy; } JClass;
typedef struct { u8 *code; int code_length; } CodeAttribute;
typedef struct { u8 *pc; JClass *clazz; } Runtime;
static int treo_diag_method_ref(JClass *cl,const u8 *op,const char *owner,const char *name,const char *desc){
    (void)cl;(void)owner;(void)desc;
    return (strcmp(name,"equals")==0 && op[1]==1) ||
           (strcmp(name,"readLine")==0 && op[1]==2) ||
           (strcmp(name,"d")==0 && op[1]==3);
}
"""
GATE_MAIN = r"""
int main(void) {
    // Mirrors the relative layout of Class_bz.c 142..151, 542..551.
    u8 code[560]={0};JClass cl={0};CodeAttribute ca={code,560};Runtime rt={code+151,&cl};
    code[142]=op_invokevirtual;code[143]=1;
    code[145]=op_putstatic;code[146]=9;
    code[148]=op_getstatic;code[149]=9;
    s16 offset=391;memcpy(code+152,&offset,2);
    code[542]=op_aconst_null;code[543]=op_putstatic;
    code[546]=op_aload;code[548]=op_invokevirtual;code[549]=2;
    code[551]=op_invokestatic;code[552]=3;
    if(!treo_diag_version_gate(&rt,&ca))return 1;
    code[543]=op_putstatic_ref;code[142]=op_invokevirtual_fast;
    code[145]=op_putstatic_byte;code[148]=op_getstatic_byte;
    code[548]=op_invokevirtual_fast;code[551]=op_invokestatic_fast;
    if(!treo_diag_version_gate(&rt,&ca))return 2;
    offset=395;memcpy(code+152,&offset,2);
    if(!treo_diag_version_gate(&rt,&ca))return 3;
    ca.code_length=553;if(treo_diag_version_gate(&rt,&ca))return 4;ca.code_length=560;
    code[552]=4;if(treo_diag_version_gate(&rt,&ca))return 5;code[552]=3;
    code[149]=8;if(treo_diag_version_gate(&rt,&ca))return 6;
    return 0;
}
"""
class StringEqualsContractTest(unittest.TestCase):
    def run_c(self, text):
        cc=shutil.which("cc")
        if not cc:self.skipTest("host C compiler unavailable")
        with tempfile.TemporaryDirectory() as td:
            src=Path(td)/"test.c"; exe=Path(td)/"test"
            src.write_text(text)
            subprocess.run([cc,"-std=c11","-Wall","-Wextra",str(src),"-o",str(exe)],check=True,timeout=30)
            subprocess.run([str(exe)],check=True,timeout=10)

    def test_equals_types_offsets_and_embedded_nul(self):
        s=(CORE/"jvm_util.c").read_text()
        a=s.index("s32 jstring_equals(");b=s.index("s32 jstring_2_utf8(",a)
        self.run_c(STRING_STUB+s[a:b]+STRING_MAIN)

    def test_version_gate_with_optional_popup_reset(self):
        s=(CORE/"interpreter.c").read_text()
        a=s.index("static int treo_diag_version_gate(");b=s.index("static void treo_diag_popup_origin(",a)
        self.run_c(GATE_STUB+s[a:b]+GATE_MAIN)

if __name__=="__main__":unittest.main()
