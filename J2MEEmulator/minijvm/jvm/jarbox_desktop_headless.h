/* Desktop-only experimental bridge to the audited Nick glyph contraction.
 * The real iOS executor is unchanged. Reuse the VM preflight and reference
 * lane replay, with a desktop TLS screen lease and build-bound API identity. */
#include "jarbox_residual_binding.h"
#include "jarbox_glyph_vm.h"
#include "mbedtls/sha256.h"
extern int jarbox_lab_sink_level(int64_t context);
extern void jarbox_lab_deep_note(unsigned kind,unsigned count);
/* Shared residual compiler above supplies the exact wrapper/link proofs. */
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

/* Exact Nick map array leaves. No cached array/data values; preserve the
 * original order of reads and the reference lane written by getstatic.
 * Refuse cold links and exceptional accesses rather than synthesize catch. */
static unsigned desktop_map_kind(MethodInfo *m){
    unsigned k=__atomic_load_n(&m->treo_array_lookup_kind,__ATOMIC_RELAXED);
    if(k)return k;
    CodeAttribute *ca=m->converted_code;
    k=1;
    if(ca&&ca->bytecode_for_jit&&ca->code_length==17&&ca->max_stack==3&&ca->max_locals==3&&
       ca->exception_table_length==1&&ca->exception_table&&
       jbr_eq(m->_this_class->name,"Class_hii")&&jbr_eq(m->descriptor,"(II)I")){
        const u8 *c=ca->bytecode_for_jit;
        const ExceptionTable *e=ca->exception_table;
        if(c[0]==0xb2&&c[3]==0x1b&&c[4]==0xb2&&c[7]==0x68&&
           c[8]==0x1a&&c[9]==0x60&&c[11]==0xac&&c[12]==0x4d&&
           c[13]==0x11&&jbg_u16(c+14)==1000&&c[16]==0xac&&
           e->start_pc==0&&e->end_pc==11&&e->handler_pc==12){
            if(c[10]==0x2e&&jbr_eq(m->name,"q3"))k=2;
            if(c[10]==0x34&&jbr_eq(m->name,"m3"))k=3;
        }
    }
    __atomic_store_n(&m->treo_array_lookup_kind,k,__ATOMIC_RELAXED);
    return k;
}
static FieldInfo *desktop_map_field(JClass *cl,unsigned ix,const char *name,const char *desc,unsigned bytes,int ref){
    ConstantItem *item=jbg_item(cl,ix);
    if(!item||item->tag!=CONSTANT_FIELD_REF)return NULL;
    ConstantFieldRef *f=(ConstantFieldRef *)item;
    FieldInfo *fi=f->fieldInfo;
    if(!fi||fi->_this_class!=cl||!jbr_eq(f->name,name)||!jbr_eq(f->descriptor,desc)||
       !jbr_eq(fi->name,name)||!jbr_eq(fi->descriptor,desc)||
       !(fi->access_flags&ACC_STATIC)||(fi->access_flags&ACC_VOLATILE)||fi->isvolatile||
       !!fi->isrefer!=ref||fi->datatype_bytes!=bytes||!cl->field_static||
       cl->field_static_len<(s32)bytes||(size_t)fi->offset>(size_t)cl->field_static_len-bytes)
        return NULL;
    return fi;
}
static int desktop_map_leaf(MethodInfo *m,Runtime *r){
    if(!m->is_static||m->para_slots!=2||m->return_slots!=1||m->is_native||m->is_sync||
       jarbox_lab_sink_level(0)<4||r->jvm->jdwp_enable||r->thrd_info->is_stop||
       r->thrd_info->suspend_count||m->breakpoint||m->_this_class->status!=CLASS_STATUS_CLINITED)return 0;
    unsigned kind=desktop_map_kind(m);
    if(kind<2)return 0;
    CodeAttribute *ca=m->converted_code;
    const u8 *c=ca->bytecode_for_jit;
    JClass *cl=m->_this_class;
    FieldInfo *af=desktop_map_field(cl,jbg_u16(c+1),kind==2?"x3":"u3",kind==2?"[I":"[C",sizeof(__refer),1);
    FieldInfo *wf=desktop_map_field(cl,jbg_u16(c+5),"j1","I",4,0);
    RuntimeStack *s=r->stack;
    if(!af||!wf||stack_size(s)<2||s->store+s->max_size-s->sp<4){
        jarbox_lab_deep_note(9,1);return 0;
    }
    void *ap=getStaticFieldPtr(af),*wp=getStaticFieldPtr(wf);
    if((uintptr_t)ap%_Alignof(__refer)||(uintptr_t)wp%_Alignof(s32)){
        jarbox_lab_deep_note(9,1);return 0;
    }
    StackEntry *args=s->sp-2;
    Instance *arr=__atomic_load_n((__refer *)ap,__ATOMIC_RELAXED);
    s32 width=__atomic_load_n((s32 *)wp,__ATOMIC_RELAXED);
    uint32_t idx;
    if(!arr||arr->mb.type!=MEM_TYPE_ARR||!arr->arr_body||
       arr->mb.arr_type_index!=(kind==2?DATATYPE_INT:DATATYPE_JCHAR)||
       !jarbox_array_index(args[0].ivalue,args[1].ivalue,width,arr->arr_length,&idx)){
        jarbox_lab_deep_note(9,1);return 0;
    }
    s32 value=kind==2?((s32 *)arr->arr_body)[idx]:((u16 *)arr->arr_body)[idx];
    args[3].rvalue=arr;
    s->sp=args;push_int(s,value);
    jarbox_lab_deep_note(kind==2?7:8,1);
    return 1;
}
