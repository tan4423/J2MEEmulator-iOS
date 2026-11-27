#ifndef JARBOX_GLYPH_VM_H
#define JARBOX_GLYPH_VM_H
/* Included only by interpreter.c after jvm.h. No resolver, allocation, Java
 * call or safepoint is permitted between preflight and commit. */
#include "jarbox_glyph_loop.h"
#include <stddef.h>
extern s32 java_lang_String_charAt0(Runtime *,JClass *);
extern s32 java_lang_String_indexOf(Runtime *,JClass *);
static inline MethodInfo *jarbox_virtual_lookup(MiniJVM *,ConstantMethodRef *,Instance *);

typedef struct {Instance *font,*wrapper,*row,*image; unsigned count;} JbgProof;
static inline int jbg_obj(Instance *o,JClass *cl){
    return o&&cl&&o->mb.type==MEM_TYPE_INS&&o->mb.clazz==cl&&o->obj_fields&&
           cl->status==CLASS_STATUS_CLINITED;
}
static inline int jbg_named(Instance *o,const char *name){
    return o&&o->mb.type==MEM_TYPE_INS&&o->mb.clazz&&o->mb.clazz->name&&
           utf8_equals_c(o->mb.clazz->name,name)&&jbg_obj(o,o->mb.clazz);
}
static inline int jbg_layout(FieldInfo *f,JClass *cl,size_t bytes,int ref){
    return f&&f->_this_class==cl&&!(f->access_flags&(ACC_STATIC|ACC_VOLATILE))&&
        !f->isvolatile&&!!f->isrefer==ref&&f->datatype_bytes==bytes&&
        cl->field_instance_len>=(s32)bytes&&
        (size_t)f->offset_instance<=(size_t)cl->field_instance_len-bytes;
}
static inline Instance *jbg_ref(Instance *o,FieldInfo *f){
    Instance *v=NULL;memcpy(&v,o->obj_fields+f->offset_instance,sizeof v);return v;
}
static inline int jbg_text(Runtime *r,Instance *o,JbgText *out){
    if(!jbg_named(o,"java/lang/String")||o->mb.clazz->jloader)return 0;
    JClass *cl=o->mb.clazz;
    ShortCut *s=&r->jvm->shortcut;
    if(!jbg_layout(s->string_count,cl,4,0)||!jbg_layout(s->string_offset,cl,4,0)||
       !jbg_layout(s->string_value,cl,sizeof(Instance *),1))return 0;
    s32 n,off;
    memcpy(&n,o->obj_fields+s->string_count->offset_instance,4);
    memcpy(&off,o->obj_fields+s->string_offset->offset_instance,4);
    Instance *a=jbg_ref(o,s->string_value);
    if(n<0||off<0||!a||a->mb.type!=MEM_TYPE_ARR||a->mb.arr_type_index!=DATATYPE_JCHAR||
       off>a->arr_length||n>a->arr_length-off||(n&&!a->arr_body))return 0;
    out->count=(unsigned)n;
    out->data=a->arr_body?(const unsigned char *)a->arr_body+2u*(size_t)off:NULL;
    return 1;
}
static inline uint16_t jbg_u16(const uint8_t *p){uint16_t v;memcpy(&v,p,2);return v;}
static inline ConstantItem *jbg_item(JClass *cl,unsigned ix){
    return cl&&cl->constant_item_ptr&&ix&&ix<(unsigned)cl->constant_item_count?
        class_get_constant_item(cl,ix):NULL;
}
static inline ConstantItem *jbg_cp_at(MethodInfo *m,unsigned pc,unsigned opcode){
    CodeAttribute *ca=m?m->converted_code:NULL;
    if(!ca||!ca->bytecode_for_jit||ca->code_length<3||
       pc>(unsigned)ca->code_length-3||ca->bytecode_for_jit[pc]!=opcode)return NULL;
    return jbg_item(m->_this_class,jbg_u16(ca->bytecode_for_jit+pc+1));
}
static inline FieldInfo *jbg_field_at(MethodInfo *m,unsigned pc,const char *name,
                                      const char *desc,size_t bytes,int ref){
    ConstantItem *item=jbg_cp_at(m,pc,0xb4);
    if(!item||item->tag!=CONSTANT_FIELD_REF)return NULL;
    ConstantFieldRef *c=(ConstantFieldRef *)item;FieldInfo *f=c->fieldInfo;
    if(!jbg_layout(f,m->_this_class,bytes,ref)||!f->name||!f->descriptor||
       !utf8_equals_c(f->name,name)||!utf8_equals_c(f->descriptor,desc))return NULL;
    return f;
}
static inline ConstantMethodRef *jbg_methodref_at(MethodInfo *m,unsigned pc){
    ConstantItem *item=jbg_cp_at(m,pc,0xb6);
    return item&&item->tag==CONSTANT_METHOD_REF?(ConstantMethodRef *)item:NULL;
}
static inline MethodInfo *jbg_virtual(Runtime *r,MethodInfo *caller,unsigned pc,
                                      Instance *receiver,const char *name,const char *desc){
    ConstantMethodRef *mr=jbg_methodref_at(caller,pc);
    if(!mr||!receiver||!receiver->mb.clazz||!mr->clsName||!mr->name||!mr->descriptor||
       !utf8_equals(mr->clsName,receiver->mb.clazz->name)||
       !utf8_equals_c(mr->name,name)||!utf8_equals_c(mr->descriptor,desc))return NULL;
    MethodInfo *m=mr->methodInfo?mr->methodInfo:jarbox_virtual_lookup(r->jvm,mr,receiver);
    if(!m||m->_this_class!=receiver->mb.clazz||!m->name||!m->descriptor||
       !utf8_equals_c(m->name,name)||!utf8_equals_c(m->descriptor,desc)||
       m->is_static||m->is_sync||m->breakpoint)return NULL;
    return m;
}
/* The packaged bootstrap String.charAt is the checked Java forwarder to
 * native charAt0. Only its successful branch may be bypassed. The exact
 * code shape bounds its reference writes to scratch slots overwritten by
 * the glyph body. Native indexOf uses UTF-16 count/offset, first match. */
static inline int jbg_string_calls(Runtime *r,MethodInfo *m,Instance *text,Instance *alphabet){
    MethodInfo *at=jbg_virtual(r,m,63,text,"charAt","(I)C");
    MethodInfo *find=jbg_virtual(r,m,66,alphabet,"indexOf","(I)I");
    if(!at||!find||at->is_native||!find->is_native||
       find->native_func!=java_lang_String_indexOf||at->para_slots!=2||
       at->return_slots!=1||find->para_slots!=2||find->return_slots!=1)return 0;
    CodeAttribute *ca=at->converted_code;
    if(!ca||!ca->bytecode_for_jit||ca->code_length!=26||ca->max_locals!=2||
       ca->max_stack!=2||ca->exception_table_length||ca->jit.state==JIT_GEN_SUCCESS)return 0;
    const u8 *p=ca->bytecode_for_jit;
    if(p[0]!=0x1b||p[1]!=0x9b||jbg_u16(p+2)!=11||p[4]!=0x1b||
       p[5]!=0x2a||p[6]!=0xb4||p[9]!=0xa1||jbg_u16(p+10)!=11||
       p[12]!=0xbb||p[15]!=0x59||p[16]!=0xb7||p[19]!=0xbf||
       p[20]!=0x2a||p[21]!=0x1b||p[22]!=0xb6||p[25]!=0xac)return 0;
    FieldInfo *count=jbg_field_at(at,6,"count","I",4,0);
    MethodInfo *leaf=jbg_virtual(r,at,22,text,"charAt0","(I)C");
    return count==r->jvm->shortcut.string_count&&count&&leaf&&leaf->is_native&&
           leaf->native_func==java_lang_String_charAt0&&leaf->para_slots==2&&leaf->return_slots==1;
}
static inline void *jbg_vm_row(void *ctx,unsigned i){
    Instance *a=ctx,*v=NULL;
    if(!a||a->mb.type!=MEM_TYPE_ARR||a->mb.arr_type_index!=DATATYPE_ARRAY||
       a->arr_length<0||i>=(unsigned)a->arr_length||!a->arr_body)return NULL;
    memcpy(&v,a->arr_body+(size_t)i*sizeof(v),sizeof v);
    if(!v||v->mb.type!=MEM_TYPE_ARR||v->mb.arr_type_index!=DATATYPE_JINT||
       v->arr_length<4||!v->arr_body)return NULL;
    return v;
}
static inline int jbg_vm_preflight(Runtime *r,unsigned kind,const char *image_desc,JbgProof *out){
    MethodInfo *m=r->method;JClass *cl=m->_this_class;
    StackEntry *l=r->localvar;
    unsigned nslot=kind==1?6:7;
    if(!l||(kind!=1&&kind!=2)||r->localvar_slots<(int)(nslot+2)||
       l[nslot+1].ivalue!=0||l[nslot].ivalue<=0||
       l[nslot].ivalue>JBG_MAX_TEXT)return 0;
    Instance *font=l[0].rvalue,*wrapper=l[1].rvalue,*text=l[2].rvalue;
    if(!jbg_obj(font,cl)||!wrapper||(kind==2&&!jbg_obj(l[6].rvalue,cl)))return 0;
    FieldInfo *charset=jbg_field_at(m,57,"c2","Ljava/lang/String;",sizeof(Instance *),1);
    FieldInfo *table=jbg_field_at(m,kind==1?88:89,"d2","[[I",sizeof(Instance *),1);
    FieldInfo *image=jbg_field_at(m,kind==1?84:85,"b2",image_desc,sizeof(Instance *),1);
    FieldInfo *spacing=jbg_field_at(m,kind==1?140:240,"w1","I",4,0);
    if(!charset||!table||!image||!spacing)return 0;
    Instance *a=jbg_ref(font,charset),*rows=jbg_ref(font,table);
    JbgText t={0},alphabet={0};void *last=NULL;
    if(!jbg_text(r,text,&t)||!jbg_text(r,a,&alphabet)||
       t.count!=(unsigned)l[nslot].ivalue||alphabet.count>JBG_MAX_ALPHABET||
       !jbg_string_calls(r,m,text,a)||!jbg_loop_preflight(t,alphabet,jbg_vm_row,rows,&last))return 0;
    *out=(JbgProof){font,wrapper,(Instance *)last,jbg_ref(font,image),t.count};return 1;
}
#endif
