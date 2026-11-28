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
    unsigned kind=ca->code_length==154?1:ca->code_length==254?2:
                  ca->code_length==156?3:ca->code_length==256?4:0;
    if(!kind)return 0;
    unsigned state=__atomic_load_n(&ca->desktop_glyph_kind,__ATOMIC_ACQUIRE);
    if(state)return state<=4?state:0;
    static const unsigned char single[32]={0x5e,0xd4,0x14,0xd5,0x2a,0xad,0x54,0x0f,0x17,0x20,0xf1,0xcc,0x12,0xa2,0x47,0xed,0x59,0xbd,0xdb,0x36,0xb1,0xea,0x0e,0x4e,0x08,0xbb,0x91,0x20,0xe5,0x6d,0x53,0xe8};
    static const unsigned char triple[32]={0xff,0xd9,0x09,0x3b,0xb7,0xc4,0xb3,0xb4,0x52,0x48,0x4c,0x82,0x65,0xa7,0xf3,0x44,0x17,0x0c,0xf9,0xf5,0x24,0xdd,0xa6,0xd0,0x97,0x79,0xee,0x9a,0x48,0x61,0x40,0x23};
    static const unsigned char ninja_single[32]={0x66,0x2b,0xb5,0x4d,0xf2,0xb1,0xc8,0xcd,0x00,0xce,0xe5,0x3c,0x19,0xc4,0xf8,0xdd,0x65,0x62,0xf5,0x58,0x7a,0x56,0x2b,0xe8,0x64,0xfe,0x7d,0x13,0x94,0x41,0x33,0xae};
    static const unsigned char ninja_triple[32]={0x78,0x2a,0x51,0x73,0xba,0x35,0x76,0xfd,0x49,0x51,0xf6,0x47,0x27,0x59,0xf3,0x4b,0xd2,0x6a,0xcd,0xcf,0xbd,0x14,0xb0,0x94,0x75,0xb6,0xd9,0x03,0x93,0xaf,0x4d,0xb5};
    if(kind<=2){
        if(m->is_static||m->is_sync||m->is_native||m->return_slots||
           m->para_slots!=5+kind||ca->max_locals!=7+kind||ca->max_stack!=10||
           ca->exception_table_length||!(m->_this_class->cff.access_flags&ACC_FINAL)||
           !jbr_eq(m->_this_class->name,"Class_hui")||!jbr_eq(m->name,"a")||
           !jbr_eq(m->descriptor,kind==1?"(LClass_hvi;Ljava/lang/String;III)V":
              "(LClass_hvi;Ljava/lang/String;IIILClass_hui;)V")||
           !jbr_live_code(ca,kind==1?154:254,kind==1?single:triple))kind=5;
    }else{
        if(m->is_static||m->is_sync||m->is_native||m->return_slots||
           m->para_slots!=(kind==3?6:7)||ca->max_locals!=(kind==3?8:9)||
           ca->max_stack!=10||ca->exception_table_length||
           !(m->_this_class->cff.access_flags&ACC_FINAL)||
           !jbr_eq(m->_this_class->name,"dd")||!jbr_eq(m->name,"a$render")||
           !jbr_eq(m->descriptor,kind==3?"(Lt;Ljava/lang/String;III)V":
              "(Lt;Ljava/lang/String;IIILdd;)V")||
           !jbr_live_code(ca,kind==3?156:256,kind==3?ninja_single:ninja_triple))kind=5;
    }
    __atomic_store_n(&ca->desktop_glyph_kind,kind,__ATOMIC_RELEASE);
    return kind<=4?kind:0;
}

/* Diagnostic only; cached role belongs to the loaded MethodInfo. */
static unsigned desktop_liveness_role(MethodInfo *m){
    unsigned role=__atomic_load_n(&m->desktop_liveness_role,__ATOMIC_RELAXED);
    if(role)return role;
    role=1;
    JClass *cl=m->_this_class;
    if(jbr_bname(cl,"Class_hcb")&&jbr_eq(m->name,"a"))role=2;
    else if(jbr_bname(cl,"Class_bn")&&jbr_eq(m->name,"run")&&jbr_eq(m->descriptor,"()V"))role=3;
    else if(jbr_bname(cl,"Class_hac")&&jbr_eq(m->name,"a")&&jbr_eq(m->descriptor,"()V"))role=4;
    __atomic_store_n(&m->desktop_liveness_role,role,__ATOMIC_RELAXED);
    return role;
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
    if(m->return_slots||m->para_slots<4||jarbox_lab_sink_level(0)<2||
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
    const int ninja=kind>=3;
    Instance *w=r->localvar[1].rvalue;
    JarBoxResidualBinding b;
    if(!w||(ninja?!jbr_ninja_glyph_binding(r,w,&b):!jbr_nick_glyph_binding(r,w,&b))||
       jarbox_lab_sink_level(b.context)<3){
        jarbox_lab_deep_note(2,1);return 0;
    }
    const unsigned call_pc=kind==1?126:kind==2?129:kind==3?124:224;
    ConstantMethodRef *mr=jbg_methodref_at(r->method,call_pc);
    const char *desc="(Ljavax/microedition/lcdui/Image;IIIIIIII)V";
    static const unsigned char wrapper_digest[32]={0x0f,0xd2,0x09,0x76,0xfe,0x8b,0x7f,0x81,0xb6,0xbb,0xcc,0x82,0x87,0x69,0x20,0xc0,0xa8,0x81,0xa1,0x89,0x7b,0x1a,0xc6,0xa2,0x49,0xdf,0xd1,0x99,0xa2,0xa5,0x17,0xf5};
    MethodInfo *wm=jbr_live_declared(w->mb.clazz,"a",desc);
    MethodInfo *gm=jbr_live_declared(b.graphics->mb.clazz,"drawRegion",desc);
    if(!mr||!wm||!gm||!jbr_eq(mr->clsName,ninja?"t":"Class_hvi")||
       !jbr_eq(mr->name,"a")||!jbr_eq(mr->descriptor,desc)||
       !jbr_live_target_ready(r->jvm,mr,w,wm)||
       wm->breakpoint||gm->breakpoint||wm->para_slots!=10||gm->para_slots!=10||
       wm->return_slots||gm->return_slots||!wm->converted_code||
       wm->converted_code->max_locals!=10||wm->converted_code->max_stack!=10||
       wm->converted_code->exception_table_length||
       wm->converted_code->jit.state==JIT_GEN_SUCCESS||!desktop_graphics_leaf_kind(gm)||
       (ninja?!jbr_live_code(wm->converted_code,31,wrapper_digest):
               !jbr_live_wrapper_ready(r->jvm,w,&(JarBoxResidualScope){.context=b.context,.wrapper=(uintptr_t)b.wrapper,.canvas=(uintptr_t)b.canvas,.graphics=(uintptr_t)b.graphics},0))){
        jarbox_lab_deep_note(3,1);return 0;
    }
    JbgProof proof;
    if(ninja?!jbg_ninja_vm_preflight(r,kind,"Ljavax/microedition/lcdui/Image;",&proof):
              !jbg_vm_preflight(r,kind,"Ljavax/microedition/lcdui/Image;",&proof)){
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
       !jarbox_lab_array_lookup_enabled()||jarbox_lab_sink_level(0)!=1||r->jvm->jdwp_enable||r->thrd_info->is_stop||
       r->thrd_info->suspend_count||m->breakpoint||m->_this_class->status!=CLASS_STATUS_CLINITED)return 0;
    unsigned kind=desktop_map_kind(m);
    if(kind!=2)return 0;
    CodeAttribute *ca=m->converted_code;
    const u8 *c=ca->bytecode_for_jit;
    JClass *cl=m->_this_class;
    RuntimeStack *s=r->stack;
    if(stack_size(s)<2||s->store+s->max_size-s->sp<4){
        jarbox_lab_deep_note(9,1);return 0;
    }
    // The CodeAttribute belongs to this loaded class. Only immutable
    // offsets from naturally resolved fields are published, never array
    // references or values. Cold linkage remains eligible for later retry.
    uint64_t layout=__atomic_load_n(&ca->desktop_map_layout,__ATOMIC_ACQUIRE);
    if(!layout){
        FieldInfo *af=desktop_map_field(cl,jbg_u16(c+1),"x3","[I",sizeof(__refer),1);
        FieldInfo *wf=desktop_map_field(cl,jbg_u16(c+5),"j1","I",4,0);
        if(!af||!wf){jarbox_lab_deep_note(9,1);return 0;}
        layout=(UINT64_C(1)<<32)|((uint64_t)af->offset<<16)|wf->offset;
        __atomic_store_n(&ca->desktop_map_layout,layout,__ATOMIC_RELEASE);
        jarbox_lab_deep_note(14,1);
    } else jarbox_lab_deep_note(15,1);
    unsigned ao=(uint16_t)(layout>>16),wo=(uint16_t)layout;
    if(!cl->field_static||cl->field_static_len<0||
       (size_t)ao+sizeof(__refer)>(size_t)cl->field_static_len||
       (size_t)wo+sizeof(s32)>(size_t)cl->field_static_len){
        jarbox_lab_deep_note(9,1);return 0;
    }
    void *ap=cl->field_static+ao,*wp=cl->field_static+wo;
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
    s32 value=((s32 *)arr->arr_body)[idx];
    args[3].rvalue=arr;
    s->sp=args;push_int(s,value);
    jarbox_lab_deep_note(7,1);
    return 1;
}

/* Independent Desktop Logic A/B. This replaces only the successful
 * instruction sequence of the bundled Vector.elementAt, AFTER the ordinary
 * synchronized method prologue. It never skips either monitor of the Nick
 * synchronized super wrapper, never caches a receiver/element, and never
 * synthesizes an exception. Leave the ordinary areturn handler in charge. */
extern int jarbox_lab_vector_enabled(void);
static int desktop_vector_body(Runtime *r,StackEntry *sp){
    MethodInfo *m=r->method;CodeAttribute *ca=m->converted_code;JClass *cl=m->_this_class;
    StackEntry *l=r->localvar;RuntimeStack *s=r->stack;
    if(!jarbox_lab_vector_enabled()||r->jvm->jdwp_enable||
       r->thrd_info->is_stop||r->thrd_info->suspend_count||m->breakpoint||
       !jbr_eq(cl->name,"java/util/Vector")||!jbr_eq(m->name,"elementAt")||
       !jbr_eq(m->descriptor,"(I)Ljava/lang/Object;")||
       !m->is_sync||m->is_static||m->is_native||m->para_slots!=2||m->return_slots!=1||
       ca->code_length!=49||ca->max_locals!=2||ca->max_stack!=4||
       ca->exception_table_length||!ca->bytecode_for_jit||
       cl->jloader||cl->status!=CLASS_STATUS_CLINITED||
       !l||sp!=l+2||s->store+s->max_size-sp<4)return 0;
    Instance *v=l[0].rvalue;
    if(!v||v->mb.type!=MEM_TYPE_INS||!v->mb.clazz||!v->obj_fields)return 0;
    // Preserve the VM's existing synchronized-method policy exactly:
    // when monitor handling is active, this receiver must be locked;
    // when the VM explicitly ignores sync (e.g. its NULL-server mode), no
    // lock may be present. Never add, drop, or bypass an acquired monitor.
    int sync_ignored=jdwp_is_ignore_sync(r->jvm->jdwpserver);
    if(sync_ignored ? r->lock!=NULL : r->lock!=(MemoryBlock *)v)return 0;
    if(v->mb.clazz!=cl&&(v->mb.clazz->superclass!=cl||
       !jbr_eq(v->mb.clazz->name,"Class_hjf")))return 0;
    uint64_t layout=__atomic_load_n(&ca->desktop_vector_layout,__ATOMIC_ACQUIRE);
    if(!layout){
        const u8 *c=ca->bytecode_for_jit;
        // Exact original boot-archive bytecode; exceptional path untouched.
        if(c[0]!=0x1b||c[1]!=0x2a||c[2]!=0xb4||c[5]!=0xa1||
           jbg_u16(c+6)!=37||c[42]!=0x2a||c[43]!=0xb4||
           c[46]!=0x1b||c[47]!=0x32||c[48]!=0xb0)return 0;
        FieldInfo *n=jbg_field_at(m,2,"elementCount","I",4,0);
        FieldInfo *a=jbg_field_at(m,43,"elementData","[Ljava/lang/Object;",sizeof(Instance *),1);
        if(!n||!a||(size_t)n->offset_instance>UINT16_MAX||
           (size_t)a->offset_instance>UINT16_MAX)return 0;
        layout=(UINT64_C(1)<<32)|((uint64_t)n->offset_instance<<16)|a->offset_instance;
        __atomic_store_n(&ca->desktop_vector_layout,layout,__ATOMIC_RELEASE);
    }
    unsigned no=(uint16_t)(layout>>16),ao=(uint16_t)layout;
    if(v->mb.clazz->field_instance_len<0||
       (size_t)no+sizeof(s32)>(size_t)v->mb.clazz->field_instance_len||
       (size_t)ao+sizeof(Instance *)>(size_t)v->mb.clazz->field_instance_len)return 0;
    s32 index=l[1].ivalue,n;
    memcpy(&n,v->obj_fields+no,sizeof(n));
    // Out-of-range indices fall back to the original VM exception path.
    if(index<0||index>=n){jarbox_lab_deep_note(17,1);return 0;}
    Instance *a=NULL,*result=NULL;
    memcpy(&a,v->obj_fields+ao,sizeof(a));
    if(!a||a->mb.type!=MEM_TYPE_ARR||a->mb.arr_type_index!=DATATYPE_REFERENCE||
       index>=a->arr_length||!a->arr_body){jarbox_lab_deep_note(17,1);return 0;}
    memcpy(&result,a->arr_body+(size_t)index*sizeof(result),sizeof(result));
    // Replay the exact live reference lanes left by the original bytecodes.
    sp[0].ivalue=index;sp[0].rvalue=result;
    sp[1].rvalue=v;sp[1].ivalue=index;
    s->sp=sp+1;
    r->pc=ca->code+48;
    jarbox_lab_deep_note(16,1);
    return 1;
}
