#include <stdint.h>
#include <stddef.h>
#include <assert.h>
#include <stdio.h>
#include <string.h>
typedef int32_t s32; typedef uint16_t u16; typedef void *__refer;
enum {ACC_STATIC=8,ACC_VOLATILE=64,CLASS_STATUS_CLINITED=5,MEM_TYPE_INS=2,MEM_TYPE_ARR=4,DATATYPE_JCHAR=5};
typedef struct {void *jloader;s32 status,field_instance_len;} JClass;
typedef struct {JClass *_this_class;unsigned access_flags,isvolatile,isrefer,datatype_bytes,offset_instance;} FieldInfo;
typedef struct {FieldInfo *string_count,*string_offset,*string_value;} ShortCut;
typedef struct {ShortCut shortcut;} MiniJVM;
typedef struct {int type,arr_type_index;JClass *clazz;} Block;
typedef struct {Block mb;unsigned char *obj_fields;void *arr_body;s32 arr_length;} Instance;
typedef union {__refer rvalue;s32 ivalue;} StackEntry;
typedef struct {StackEntry *sp,*store;s32 max_size;} RuntimeStack;
typedef struct {MiniJVM *jvm;RuntimeStack *stack;} Runtime;
typedef struct {int is_native,is_static,is_sync,para_slots,return_slots;void *breakpoint;JClass *_this_class;s32 (*native_func)(Runtime *,JClass *);} MethodInfo;
s32 java_lang_String_charAt0(Runtime *r,JClass *c){(void)r;(void)c;return 0;}
static s32 other(Runtime *r,JClass *c){(void)r;(void)c;return 0;}
static void push_int(RuntimeStack *s,s32 n){(s->sp++)->ivalue=n;}
#include "jarbox_char_leaf.h"
static void set_field(unsigned char *p,s32 n,s32 off,Instance *a){__refer v=a;memcpy(p+1,&n,4);memcpy(p+5,&off,4);memcpy(p+9,&v,sizeof(v));}
static void setup(RuntimeStack *s,Instance *str,s32 idx){s->sp=s->store+3;s->store[0].ivalue=123456;s->store[1].rvalue=str;s->store[2].ivalue=idx;}
static void reject(MethodInfo *m,Runtime *r){StackEntry saved[4];memcpy(saved,r->stack->store,sizeof(saved));StackEntry *sp=r->stack->sp;assert(!jarbox_try_char_leaf(m,r));assert(r->stack->sp==sp&&!memcmp(saved,r->stack->store,sizeof(saved)));}
int main(void){
 JClass cl={0,5,32}, foreign={0,5,32};
 FieldInfo count={&cl,0,0,0,4,1},off={&cl,0,0,0,4,5},val={&cl,0,0,1,sizeof(__refer),9};
 MiniJVM vm={{&count,&off,&val}}; StackEntry cells[8]={0};RuntimeStack stack={cells,cells,8};Runtime r={&vm,&stack};
 MethodInfo m={1,0,0,2,1,0,&cl,java_lang_String_charAt0};
 unsigned char fields[32]={0}; u16 data[65536];for(unsigned i=0;i<65536;i++)data[i]=(u16)i;
 Instance a={{MEM_TYPE_ARR,DATATYPE_JCHAR,0},0,data,65536},s={{MEM_TYPE_INS,0,&cl},fields,0,0};
 set_field(fields,65536,0,&a);
 for(unsigned i=0;i<65536;i++){setup(&stack,&s,(s32)i);assert(jarbox_try_char_leaf(&m,&r));assert(stack.sp==cells+2&&cells[0].ivalue==123456&&cells[1].ivalue==(s32)i);}
 uint32_t rng=1;
 for(unsigned i=0;i<100000;i++){rng=rng*1664525u+1013904223u;unsigned start=rng%65000;unsigned len=65536-start;unsigned idx=(rng>>8)%len;set_field(fields,(s32)len,(s32)start,&a);setup(&stack,&s,(s32)idx);assert(jarbox_try_char_leaf(&m,&r)&&cells[1].ivalue==(s32)(start+idx));}
 set_field(fields,2,7,&a);setup(&stack,&s,0);
 #define REJECT_CHANGE(field,value) do {__typeof__(field) old=(field);(field)=(value);reject(&m,&r);(field)=old;}while(0)
 REJECT_CHANGE(m.native_func,other);REJECT_CHANGE(m.native_func,NULL);REJECT_CHANGE(m.is_native,0);REJECT_CHANGE(m.is_static,1);REJECT_CHANGE(m.is_sync,1);REJECT_CHANGE(m.breakpoint,&m);REJECT_CHANGE(m.para_slots,1);REJECT_CHANGE(m.return_slots,0);REJECT_CHANGE(cl.jloader,&cl);REJECT_CHANGE(cl.status,4);REJECT_CHANGE(count._this_class,&foreign);REJECT_CHANGE(off.access_flags,ACC_STATIC);REJECT_CHANGE(val.isvolatile,1);REJECT_CHANGE(count.datatype_bytes,2);REJECT_CHANGE(val.offset_instance,31);REJECT_CHANGE(s.mb.clazz,&foreign);REJECT_CHANGE(s.mb.type,MEM_TYPE_ARR);REJECT_CHANGE(s.obj_fields,NULL);REJECT_CHANGE(a.mb.arr_type_index,6);REJECT_CHANGE(a.mb.type,MEM_TYPE_INS);REJECT_CHANGE(a.arr_body,NULL);REJECT_CHANGE(a.arr_length,8);REJECT_CHANGE(cells[1].rvalue,NULL);REJECT_CHANGE(cells[2].ivalue,-1);REJECT_CHANGE(cells[2].ivalue,2);REJECT_CHANGE(stack.max_size,3);
 set_field(fields,2,-1,&a);reject(&m,&r);set_field(fields,2,65535,&a);reject(&m,&r);set_field(fields,2,7,NULL);reject(&m,&r);
 MiniJVM second={{&count,&off,&val}};r.jvm=&second;FieldInfo foreign_count=count;foreign_count._this_class=&foreign;second.shortcut.string_count=&foreign_count;set_field(fields,2,7,&a);reject(&m,&r);
 puts("PASS 65536 UTF-16 code units, 100000 slices, 30 rejection cases and stack/owner checks");
}
