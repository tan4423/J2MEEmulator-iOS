/* Desktop-only experimental bridge to the audited Nick glyph contraction.
 * The real iOS executor is unchanged. Reuse the VM preflight and reference
 * lane replay, with a desktop TLS screen lease and build-bound API identity. */
#include "jarbox_residual_binding.h"
#include "jarbox_glyph_vm.h"
#include "mbedtls/sha256.h"
extern int jarbox_lab_sink_level(int64_t context);
extern void jarbox_lab_deep_note(unsigned kind,unsigned count);
static int jbr_eq(Utf8String *s,const char *str) { return s && utf8_equals_c(s,str); }
// Host oracle only: resolution must have occurred naturally in the original
// interpreter. Never resolve, initialize, pin, or sample a field's value here.
// Metadata must be owned by this loaded class's loader and still valid.
static int jbr_plain_int_read(JClass *cl,ConstantFieldRef *ref) {
    FieldInfo *f=ref->fieldInfo;
    if(!f||!f->_this_class||f->isrefer||f->isvolatile||
       !(f->access_flags&8)||(f->access_flags&0x40))return 0;
    JClass *owner=f->_this_class;
    if(owner->status!=CLASS_STATUS_CLINITED||owner->jloader!=cl->jloader||
       !owner->name||!ref->clsName||!utf8_equals(owner->name,ref->clsName)||
       !f->name||!ref->name||!utf8_equals(f->name,ref->name)||
       !f->descriptor||!ref->descriptor||!utf8_equals(f->descriptor,ref->descriptor))return 0;
    unsigned bytes=jbr_eq(f->descriptor,"I")?4:jbr_eq(f->descriptor,"S")?2:(jbr_eq(f->descriptor,"B")||jbr_eq(f->descriptor,"Z"))?1:0;
    return bytes&&f->datatype_bytes==bytes&&owner->field_static&&owner->field_static_len>=0&&
        (size_t)f->offset+bytes<=(size_t)owner->field_static_len;
}
static int jbr_live_code(const CodeAttribute *ca,unsigned length,const unsigned char digest[32]) {
    unsigned char actual[32];
    return ca&&ca->bytecode_for_jit&&ca->code_length==length&&
        !mbedtls_sha256_ret(ca->bytecode_for_jit,length,actual,0)&&!memcmp(actual,digest,32);
}
static MethodInfo *jbr_live_declared(JClass *c,const char *name,const char *desc) {
    if(!c||c->status!=CLASS_STATUS_CLINITED||!c->methodPool.method||
       c->methodPool.method_used<0||c->methodPool.method_used>4096)return NULL;
    MethodInfo *found=NULL;
    for(int i=0;i<c->methodPool.method_used;i++){
        MethodInfo *m=c->methodPool.method+i;
        if(!jbr_eq(m->name,name)||!jbr_eq(m->descriptor,desc))continue;
        if(found||m->_this_class!=c||m->is_static||m->is_native||m->is_sync||
           !m->converted_code||m->converted_code->exception_table_length||
           !(m->access_flags&ACC_PUBLIC))return NULL;
        found=m;
    }
    return found;
}
static inline MethodInfo *jarbox_virtual_lookup(MiniJVM *,ConstantMethodRef *,Instance *);
static int jbr_live_target_ready(MiniJVM *vm,ConstantMethodRef *mr,Instance *receiver,MethodInfo *expected) {
    return mr&&expected&&(!mr->methodInfo||mr->methodInfo==expected)&&
           (mr->methodInfo==expected||jarbox_virtual_lookup(vm,mr,receiver)==expected);
}
// Variant 0 region, 1 image, 2 drawRect, 3 fillRect; generic tiers also
// use 4 line, 5 roundRect, 6 fillRoundRect, 7 arc. Graphics state
// operations (clip, translation, color and queries) remain ordinary.
static int jbr_live_wrapper_ready(MiniJVM *vm,Instance *w,const JarBoxResidualScope *scope,unsigned variant) {
    static const unsigned char digest[32]={0x13,0xca,0x49,0xde,0x94,0x27,0xbe,0x04,0xff,0xe4,0xb4,0xe0,0xe3,0xa9,0x6a,0xf0,0x0e,0x0d,0x16,0x56,0x20,0x93,0xf8,0x93,0x6a,0x1c,0xa1,0x18,0xf3,0xa8,0x7f,0xa1};
    static const unsigned char image_digest[32]={0x1e,0xe7,0x75,0x00,0xc0,0x72,0xc0,0x94,0xc3,0x87,0x4f,0x28,0xef,0x0f,0xc4,0x48,0x0a,0xd9,0xac,0x0c,0xa2,0xce,0x1e,0x6b,0x52,0x8e,0x21,0x71,0x77,0x09,0x64,0xcc};
    static const unsigned char rect_digest[32]={0x73,0xb1,0xc9,0xbe,0xf7,0x6d,0x1b,0x44,0x57,0x75,0x35,0x26,0x5e,0xf2,0xe1,0x06,0xc9,0x8c,0xb3,0x9a,0xb0,0xb9,0x82,0x7c,0x0e,0x49,0x8d,0x9d,0xf5,0x73,0x40,0x91};
    static const unsigned char fill_digest[32]={0xf9,0x70,0x36,0x5c,0x2b,0x2f,0x1a,0xb0,0x24,0x5b,0x63,0xff,0x3e,0x12,0xfc,0xe6,0xd4,0x8d,0x70,0xb3,0x86,0x13,0xbe,0x9c,0x21,0x33,0x6a,0xfa,0xf7,0x75,0xd7,0xa1};
    static const unsigned char line_digest[32]={0x16,0xef,0x10,0x49,0xc6,0xb5,0xff,0xe2,0x97,0x21,0x69,0xd9,0x21,0xf1,0x57,0xda,0xbb,0x04,0x88,0x5f,0x43,0xfa,0xd8,0x76,0xc3,0x7c,0xc1,0x4c,0x35,0x58,0xf7,0xe3};
    static const unsigned char round_digest[32]={0x5b,0xfa,0xa7,0x10,0x35,0xf9,0x0a,0xa9,0x74,0x61,0x23,0x53,0x31,0xad,0xde,0x12,0xe7,0xd2,0xc0,0xd5,0xf2,0xcd,0x2d,0xa4,0xd1,0xcd,0xd1,0x69,0x13,0x60,0xd7,0x04};
    static const unsigned char fill_round_digest[32]={0x2b,0x83,0xae,0xf0,0xf9,0x87,0x02,0x6c,0xac,0x48,0xf7,0x7a,0xbd,0x50,0xb6,0x88,0xea,0xdf,0x25,0xb1,0xd2,0x72,0x50,0x28,0x2c,0x7b,0xb8,0x70,0x45,0x05,0xd0,0x1a};
    static const unsigned char arc_digest[32]={0xf2,0x74,0x7b,0xfb,0xb7,0x74,0x0f,0xe8,0x75,0xdf,0xb8,0x6d,0x7a,0xaf,0xc2,0x6a,0x0f,0x75,0x17,0xc7,0x38,0x7b,0xd5,0x67,0x8d,0x28,0x11,0x68,0x03,0x1f,0xa9,0xaf};
    static const char *names[]={"drawRegion","drawImage","drawRect","fillRect","drawLine","drawRoundRect","fillRoundRect","drawArc"};
    static const char *wrappers[]={"a","a","b","c","a","a","b","c"};
    static const unsigned lengths[]={67,25,39,39,39,59,59,43},
        scale_pc[]={3,2,2,2,2,2,2,2},field_pc[]={46,14,28,28,28,44,44,28},
        call_pc[]={64,22,36,36,36,56,56,40};
    if(variant>7||!w||!scope||!scope->graphics)return 0;
    const unsigned char *digests[]={digest,image_digest,rect_digest,fill_digest,line_digest,round_digest,fill_round_digest,arc_digest};
    const char *desc=variant>=5?"(IIIIII)V":variant>=2?"(IIII)V":variant==1?"(Ljavax/microedition/lcdui/Image;III)V":"(Ljavax/microedition/lcdui/Image;IIIIIIII)V";
    const char *name=names[variant];
    JClass *wc=w->mb.clazz;
    Instance *g=(Instance *)scope->graphics;
    MethodInfo *wm=jbr_live_declared(wc,wrappers[variant],desc);
    MethodInfo *gm=jbr_live_declared(g->mb.clazz,name,desc);
    if(!wm||!gm||!jbr_live_code(wm->converted_code,lengths[variant],digests[variant])||
       !jbr_bfield(wc,NULL,"g","I",4,0,1))return 0;
    // Exact JAR and packaged API identities are launch-gated. Verify that
    // the wrapper's actual CP refers to those loaded declarations. No
    // resolver or Java execution on this path.
    CodeAttribute *ca=wm->converted_code;
    unsigned ix=jbg_u16(ca->bytecode_for_jit+scale_pc[variant]);
    ConstantItem *item=ix&&ix<(unsigned)wc->constant_item_count?class_get_constant_item(wc,ix):NULL;
    if(!item||item->tag!=CONSTANT_FIELD_REF||!jbr_plain_int_read(wc,(ConstantFieldRef *)item))return 0;
    ConstantFieldRef *f=(ConstantFieldRef *)item;
    if(!jbr_eq(f->name,"g")||f->fieldInfo->_this_class!=wc)return 0;
    ix=jbg_u16(ca->bytecode_for_jit+field_pc[variant]);
    item=ix&&ix<(unsigned)wc->constant_item_count?class_get_constant_item(wc,ix):NULL;
    if(!item||item->tag!=CONSTANT_FIELD_REF)return 0;
    f=(ConstantFieldRef *)item;
    if(!f->fieldInfo||f->fieldInfo->_this_class!=wc||f->fieldInfo->isvolatile||
       !jbr_eq(f->name,"a")||!jbr_eq(f->descriptor,"Ljavax/microedition/lcdui/Graphics;"))return 0;
    ix=jbg_u16(ca->bytecode_for_jit+call_pc[variant]);
    item=ix&&ix<(unsigned)wc->constant_item_count?class_get_constant_item(wc,ix):NULL;
    if(!item||item->tag!=CONSTANT_METHOD_REF)return 0;
    ConstantMethodRef *mr=(ConstantMethodRef *)item;
    return jbr_eq(mr->clsName,"javax/microedition/lcdui/Graphics")&&
        jbr_eq(mr->name,name)&&jbr_eq(mr->descriptor,desc)&&
        jbr_live_target_ready(vm,mr,g,gm);
}

static unsigned jbg_live_kind(MethodInfo *m,CodeAttribute *ca){
    unsigned kind=ca->code_length==154?1:ca->code_length==254?2:0;
    if(!kind)return 0;
    unsigned state=__atomic_load_n(&ca->desktop_glyph_kind,__ATOMIC_ACQUIRE);
    if(state)return state<=2?state:0;
    static const unsigned char single[32]={0x5e,0xd4,0x14,0xd5,0x2a,0xad,0x54,0x0f,0x17,0x20,0xf1,0xcc,0x12,0xa2,0x47,0xed,0x59,0xbd,0xdb,0x36,0xb1,0xea,0x0e,0x4e,0x08,0xbb,0x91,0x20,0xe5,0x6d,0x53,0xe8};
    static const unsigned char triple[32]={0xff,0xd9,0x09,0x3b,0xb7,0xc4,0xb3,0xb4,0x52,0x48,0x4c,0x82,0x65,0xa7,0xf3,0x44,0x17,0x0c,0xf9,0xf5,0x24,0xdd,0xa6,0xd0,0x97,0x79,0xee,0x9a,0x48,0x61,0x40,0x23};
    if(m->is_static||m->is_sync||m->is_native||m->return_slots||
       m->para_slots!=5+kind||ca->max_locals!=7+kind||ca->max_stack!=10||
       ca->exception_table_length||!(m->_this_class->cff.access_flags&ACC_FINAL)||
       !jbr_eq(m->_this_class->name,"Class_hui")||!jbr_eq(m->name,"a")||
       !jbr_eq(m->descriptor,kind==1?"(LClass_hvi;Ljava/lang/String;III)V":
          "(LClass_hvi;Ljava/lang/String;IIILClass_hui;)V")||
       !jbr_live_code(ca,kind==1?154:254,kind==1?single:triple))kind=3;
    __atomic_store_n(&ca->desktop_glyph_kind,kind,__ATOMIC_RELEASE);
    return kind<=2?kind:0;
}

static int desktop_graphics_leaf_kind(MethodInfo *m){
    unsigned tag=__atomic_load_n(&m->treo_afk_kind,__ATOMIC_RELAXED);
    if(tag)return tag==3;
    tag=1;
    static const char *const names[][2]={
        {"drawRegion","(Ljavax/microedition/lcdui/Image;IIIIIIII)V"},
        {"drawImage","(Ljavax/microedition/lcdui/Image;III)V"},
        {"drawRect","(IIII)V"},{"fillRect","(IIII)V"},{"drawLine","(IIII)V"},
        {"drawRoundRect","(IIIIII)V"},{"fillRoundRect","(IIIIII)V"},
        {"drawArc","(IIIIII)V"},{"fillArc","(IIIIII)V"}
    };
    if(jbr_bname(m->_this_class,"javax/microedition/lcdui/Graphics")&&
       !m->is_native&&!m->is_static&&!m->is_sync&&!m->return_slots)
        for(unsigned i=0;i<sizeof(names)/sizeof(names[0]);i++)
            if(jbr_eq(m->name,names[i][0])&&jbr_eq(m->descriptor,names[i][1])){tag=3;break;}
    __atomic_store_n(&m->treo_afk_kind,tag,__ATOMIC_RELAXED);
    return tag==3;
}
static int desktop_graphics_leaf(MethodInfo *m,Runtime *r){
    if(jarbox_lab_sink_level(0)<2||m->return_slots||m->para_slots<4||
       r->jvm->jdwp_enable||r->thrd_info->is_stop||r->thrd_info->suspend_count||
       m->breakpoint||!desktop_graphics_leaf_kind(m)||stack_size(r->stack)<m->para_slots)return 0;
    StackEntry *args=r->stack->sp-m->para_slots;
    Instance *g=args->rvalue;JClass *cl=m->_this_class;int64_t context=0;
    if(!jbr_bobject(g,cl)||!jbr_bcontext(cl,g,&context)||jarbox_lab_sink_level(context)<2||
       !jbr_bzero(cl,g,"ownsContext")||!jbr_bzero(cl,g,"treoPixelDependent")||
       !jbr_bzero(cl,g,"headless"))return 0;
    r->stack->sp=args;jarbox_lab_deep_note(0,1);return 1;
}
static int desktop_glyph_skip(Runtime *r,unsigned kind,StackEntry *sp){
    if(jarbox_lab_sink_level(0)<3)return 0;
    jarbox_lab_deep_note(1,1);
    Instance *w=r->localvar[1].rvalue;
    JarBoxResidualBinding b;
    if(!jbr_nick_glyph_binding(r,w,&b)||jarbox_lab_sink_level(b.context)<3){
        jarbox_lab_deep_note(2,1);return 0;
    }
    JarBoxResidualScope scope={.context=b.context,.wrapper=(uintptr_t)b.wrapper,.canvas=(uintptr_t)b.canvas,.graphics=(uintptr_t)b.graphics};
    ConstantMethodRef *mr=jbg_methodref_at(r->method,kind==1?126:129);
    const char *desc="(Ljavax/microedition/lcdui/Image;IIIIIIII)V";
    MethodInfo *wm=jbr_live_declared(w->mb.clazz,"a",desc);
    MethodInfo *gm=jbr_live_declared(b.graphics->mb.clazz,"drawRegion",desc);
    if(!mr||!wm||!gm||!jbr_eq(mr->clsName,"Class_hvi")||!jbr_eq(mr->name,"a")||
       !jbr_eq(mr->descriptor,desc)||!jbr_live_target_ready(r->jvm,mr,w,wm)||
       wm->breakpoint||gm->breakpoint||wm->para_slots!=10||gm->para_slots!=10||
       wm->converted_code->max_locals!=10||wm->converted_code->max_stack!=10||
       wm->converted_code->jit.state==JIT_GEN_SUCCESS||!desktop_graphics_leaf_kind(gm)||
       !jbr_live_wrapper_ready(r->jvm,w,&scope,0)){
        jarbox_lab_deep_note(3,1);return 0;
    }
    JbgProof proof;
    if(!jbg_vm_preflight(r,kind,"Ljavax/microedition/lcdui/Image;",&proof)){
        jarbox_lab_deep_note(4,1);return 0;
    }
    if(jarbox_lab_sink_level(b.context)<3)return 0;
    jbg_replay(sp,w,proof.font,proof.row,b.graphics,proof.image);
    jarbox_lab_deep_note(5,1);jarbox_lab_deep_note(6,proof.count);
    return 1;
}
