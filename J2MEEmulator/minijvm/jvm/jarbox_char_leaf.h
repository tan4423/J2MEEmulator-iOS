#ifndef JARBOX_CHAR_LEAF_H
#define JARBOX_CHAR_LEAF_H
#include <stdint.h>
#include <string.h>

// Only the already resolved built-in native function may be bypassed.
// This header is included after the VM types and accessors are defined.
extern s32 java_lang_String_charAt0(Runtime *, JClass *);
static inline int jarbox_char_field(FieldInfo *f,JClass *cl,size_t bytes,int ref) {
    return f && f->_this_class==cl && !(f->access_flags&(ACC_STATIC|ACC_VOLATILE)) &&
        !f->isvolatile && !!f->isrefer==ref && f->datatype_bytes==bytes &&
        cl->field_instance_len>=(s32)bytes && (uint32_t)f->offset_instance<=(uint32_t)cl->field_instance_len-(uint32_t)bytes;
}
static inline int jarbox_try_char_leaf(MethodInfo *m,Runtime *r) {
    if (!m->is_native || m->native_func!=java_lang_String_charAt0 || m->is_static || m->is_sync ||
        m->breakpoint || m->para_slots!=2 || m->return_slots!=1) return 0;
    JClass *cl=m->_this_class;
    if (!cl || cl->jloader || cl->status<CLASS_STATUS_CLINITED) return 0;
    ShortCut *sc=&r->jvm->shortcut;
    FieldInfo *count=sc->string_count,*offset=sc->string_offset,*value=sc->string_value;
    if (!jarbox_char_field(count,cl,sizeof(s32),0) || !jarbox_char_field(offset,cl,sizeof(s32),0) ||
        !jarbox_char_field(value,cl,sizeof(__refer),1)) return 0;
    RuntimeStack *stack=r->stack;
    s32 used=(s32)(stack->sp-stack->store);
    if (used<2 || used>=stack->max_size) return 0;
    StackEntry *args=stack->sp-2;
    Instance *str=(Instance *)args[0].rvalue;
    s32 index=args[1].ivalue;
    if (!str || str->mb.type!=MEM_TYPE_INS || str->mb.clazz!=cl || !str->obj_fields || index<0) return 0;
    s32 n,off;
    __refer raw;
    memcpy(&n,str->obj_fields+count->offset_instance,sizeof(n));
    if (index>=n) return 0;
    memcpy(&off,str->obj_fields+offset->offset_instance,sizeof(off));
    memcpy(&raw,str->obj_fields+value->offset_instance,sizeof(raw));
    Instance *arr=(Instance *)raw;
    if (!arr || arr->mb.type!=MEM_TYPE_ARR || arr->mb.arr_type_index!=DATATYPE_JCHAR || !arr->arr_body ||
        off<0 || off>arr->arr_length || n>arr->arr_length-off) return 0;
    u16 ch;
    memcpy(&ch,(const unsigned char *)arr->arr_body+(size_t)(off+index)*sizeof(ch),sizeof(ch));
    stack->sp=args;
    push_int(stack,ch);
    return 1;
}
#endif
