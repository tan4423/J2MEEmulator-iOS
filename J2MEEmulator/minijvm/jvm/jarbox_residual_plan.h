#ifndef JARBOX_RESIDUAL_PLAN_H
#define JARBOX_RESIDUAL_PLAN_H
#include <stdint.h>
#include "jarbox_java_integer.h"

// Immutable, pointer-free IR. Slots 0,16..27 are references, 1..15 ints.
// Host experiment only. This header assumes the actual VM StackEntry layout.
enum { JBR_NOP, JBR_CONST, JBR_MOVE, JBR_INC, JBR_IADD, JBR_ISUB,
       JBR_IMUL, JBR_IAND, JBR_ISHR, JBR_IF_ICMPEQ, JBR_IF_ICMPNE,
       JBR_IF_ICMPGE, JBR_EFFECT, JBR_NULL, JBR_MOVE_REF,
       JBR_IF_ICMPLT,JBR_IF_ICMPGT,JBR_IF_ICMPLE,
       JBR_IFEQ,JBR_IFNE,JBR_IFLT,JBR_IFGE,JBR_IFGT,JBR_IFLE,
       JBR_WIDE_EFFECT,JBR_INEG,JBR_ISHL,JBR_IF_ACMPEQ,JBR_IF_ACMPNE,JBR_IFNULL,JBR_IFNONNULL };
enum { JBR_LOCAL4=28, JBR_SLOTS=29, JBR_NONE=255, JBR_END=65535 };
typedef struct {
    uint8_t kind,a,b,dst;
    uint16_t pc,next,alt;
    uint8_t length, checkpoint;
    int32_t imm;
} JarBoxResidualOp;
static inline int jbr_ref_slot(unsigned n) { return n==0 || (n>=16 && n<28); }
static inline int jbr_int_slot(unsigned n) { return (n>0 && n<16)||n==JBR_LOCAL4; }
static inline int jbr_two_branch(unsigned k) {
    return (k>=JBR_IF_ICMPEQ&&k<=JBR_IF_ICMPGE)||(k>=JBR_IF_ICMPLT&&k<=JBR_IF_ICMPLE);
}
static inline int jbr_one_branch(unsigned k) {return k>=JBR_IFEQ&&k<=JBR_IFLE;}
static inline int jbr_is_effect(unsigned k){return k==JBR_EFFECT||k==JBR_WIDE_EFFECT;}
static inline unsigned jbr_effect_raw(const JarBoxResidualOp *o){return (unsigned)o->imm&255u;}
static inline unsigned jbr_wide_arg(const JarBoxResidualOp *o,unsigned i){return (((unsigned)o->imm>>(8+i))&1u?16u:4u)+o->b+i;}
static inline int jbr_mixed_local(unsigned n){return n==2||n==3||n==JBR_LOCAL4;}
static inline void jbr_copy_slot(StackEntry *dst,const StackEntry *src,unsigned n) {
    if(jbr_ref_slot(n)) { dst->rvalue=src->rvalue;dst->lvalue=0; }
    else { dst->ivalue=src->ivalue;dst->rvalue=NULL; }
}
// Reject malformed structural/type operands before any residual effects.
// This is not a proof of game identity or dataflow equivalence.
static inline int jbr_validate(const JarBoxResidualOp *plan,unsigned count,
                               const unsigned char *code,unsigned size) {
    if(!plan||!code||!count||count>=JBR_END||!size||size>=JBR_END)return 0;
    for(unsigned i=0;i<count;i++) {
        const JarBoxResidualOp *o=plan+i;
        unsigned a=o->a,b=o->b,d=o->dst;
        if(o->pc>=size)return 0;
        if(o->checkpoint>1 || (o->checkpoint &&
           (o->kind!=JBR_MOVE || o->a!=0 || o->dst!=16 || code[o->pc]!=0x2a)))return 0;
        if(o->kind==JBR_EFFECT && o->imm==0xb1) {
            if(code[o->pc]!=0xb1||o->length!=1||a!=JBR_NONE||b!=JBR_NONE||
               d!=JBR_NONE||o->next!=JBR_END||o->alt!=JBR_END)return 0;
            continue;
        }
        if(o->next>=count)return 0;
        if(jbr_two_branch(o->kind)||jbr_one_branch(o->kind)) {
            if(o->alt>=count||!jbr_int_slot(a)||(jbr_two_branch(o->kind)?!jbr_int_slot(b):b!=JBR_NONE)||d!=JBR_NONE||o->length)return 0;
            continue;
        }
        if(o->kind>=JBR_IF_ACMPEQ&&o->kind<=JBR_IFNONNULL){
            if(o->alt>=count||!jbr_ref_slot(a)||d!=JBR_NONE||o->length||
               (o->kind<=JBR_IF_ACMPNE?!jbr_ref_slot(b):b!=JBR_NONE))return 0;
            continue;
        }
        if(o->alt!=JBR_END)return 0;
        if(o->kind==JBR_WIDE_EFFECT){
            unsigned raw=jbr_effect_raw(o),refs=(unsigned)o->imm>>8;
            if(!o->length||o->length>size-o->pc||code[o->pc]!=raw||
               a>12||b>12||a+b>12||(refs>>a)||
               (d!=JBR_NONE&&(b>=12||(d!=4+b&&d!=16+b))))return 0;
            switch(raw){
                case 0x12:case 0x13:if(a||d!=4+b||o->length!=(raw==0x12?2:3))return 0;break;
                case 0xb4:if(a!=1||refs!=1||d==JBR_NONE||o->length!=3)return 0;break;
                case 0xc0:if(a!=1||refs!=1||d!=16+b||o->length!=3)return 0;break;
                case 0x2e:case 0x32:if(a!=2||refs!=1||d!=(raw==0x32?16:4)+b||o->length!=1)return 0;break;
                case 0xb8:case 0xb6:if(o->length!=3||(raw==0xb6&&(!a||!(refs&1))))return 0;break;
                default:return 0;
            }
            continue;
        }
        if(o->kind==JBR_EFFECT) {
            if(!o->length||o->length>size-o->pc||code[o->pc]!=o->imm)return 0;
            switch(o->imm) {
                case 0xb2:if(o->length!=3||d==0||d>=JBR_SLOTS||a!=JBR_NONE||b!=JBR_NONE)return 0;break;
                case 0xb3:if(o->length!=3||!jbr_int_slot(a)||b!=JBR_NONE||d!=JBR_NONE)return 0;break;
                case 0x34:if(o->length!=1||!jbr_ref_slot(a)||!jbr_int_slot(b)||!jbr_int_slot(d))return 0;break;
                case 0xb8:if(o->length!=3||!jbr_int_slot(a)||!jbr_int_slot(b)||!jbr_int_slot(d))return 0;break;
                case 0xb6:if(o->length!=3||!jbr_ref_slot(a)||!jbr_ref_slot(b)||d!=JBR_NONE)return 0;break;
                case 0x6c:case 0x70:if(o->length!=1||!jbr_int_slot(a)||!jbr_int_slot(b)||!jbr_int_slot(d))return 0;break;
                default:return 0;
            }
        } else {
            if(o->length)return 0;
            switch(o->kind) {
                case JBR_NOP:if(a!=JBR_NONE||b!=JBR_NONE||d!=JBR_NONE)return 0;break;
                case JBR_CONST:if(!jbr_int_slot(d)||a!=JBR_NONE||b!=JBR_NONE)return 0;break;
                case JBR_NULL:if(!jbr_ref_slot(d)||d==0||a!=JBR_NONE||b!=JBR_NONE)return 0;break;
                case JBR_MOVE_REF:if(b!=JBR_NONE||!((jbr_mixed_local(a)&&jbr_ref_slot(d)&&d!=0)||(jbr_mixed_local(d)&&jbr_ref_slot(a))))return 0;break;
                case JBR_INEG:if(!jbr_int_slot(a)||!jbr_int_slot(d)||b!=JBR_NONE)return 0;break;
                case JBR_MOVE:if(a>=JBR_SLOTS||d==0||d>=JBR_SLOTS||
                                  jbr_ref_slot(a)!=jbr_ref_slot(d)||b!=JBR_NONE)return 0;break;
                case JBR_INC:if(!jbr_int_slot(a)||a!=d||b!=JBR_NONE)return 0;break;
                case JBR_IADD:case JBR_ISUB:case JBR_IMUL:case JBR_IAND:case JBR_ISHR:case JBR_ISHL:
                    if(!jbr_int_slot(a)||!jbr_int_slot(b)||!jbr_int_slot(d))return 0;
                    break;
                default:return 0;
            }
        }
    }
    return 1;
}
// The generated plan has been validated before execution; no effect can be
// handled here. Return a successor index, not a bytecode pointer.
static inline unsigned jbr_pure_step(const JarBoxResidualOp *o,StackEntry *v) {
    int32_t a=o->a<JBR_SLOTS?v[o->a].ivalue:0;
    int32_t b=o->b<JBR_SLOTS?v[o->b].ivalue:0;
    switch(o->kind) {
        case JBR_NOP:break;
        case JBR_CONST:v[o->dst].ivalue=o->imm;break;
        case JBR_MOVE:jbr_copy_slot(&v[o->dst],&v[o->a],o->a);break;
        case JBR_NULL:v[o->dst].rvalue=NULL;v[o->dst].lvalue=0;break;
        case JBR_MOVE_REF:v[o->dst].rvalue=v[o->a].rvalue;v[o->dst].lvalue=0;break;
        case JBR_INC:v[o->dst].ivalue=jarbox_java_iadd(a,o->imm);break;
        case JBR_IADD:v[o->dst].ivalue=jarbox_java_iadd(a,b);break;
        case JBR_ISUB:v[o->dst].ivalue=jarbox_java_isub(a,b);break;
        case JBR_IMUL:v[o->dst].ivalue=jarbox_java_imul(a,b);break;
        case JBR_IAND:v[o->dst].ivalue=a&b;break;
        case JBR_ISHR:v[o->dst].ivalue=jarbox_java_ishr(a,b);break;
        case JBR_ISHL:v[o->dst].ivalue=jarbox_java_ishl(a,b);break;
        case JBR_INEG:v[o->dst].ivalue=jarbox_java_isub(0,a);break;
        case JBR_IF_ACMPEQ:return v[o->a].rvalue==v[o->b].rvalue?o->next:o->alt;
        case JBR_IF_ACMPNE:return v[o->a].rvalue!=v[o->b].rvalue?o->next:o->alt;
        case JBR_IFNULL:return !v[o->a].rvalue?o->next:o->alt;
        case JBR_IFNONNULL:return v[o->a].rvalue?o->next:o->alt;
        case JBR_IF_ICMPEQ:return a==b?o->next:o->alt;
        case JBR_IF_ICMPNE:return a!=b?o->next:o->alt;
        case JBR_IF_ICMPGE:return a>=b?o->next:o->alt;
        case JBR_IF_ICMPLT:return a<b?o->next:o->alt;
        case JBR_IF_ICMPGT:return a>b?o->next:o->alt;
        case JBR_IF_ICMPLE:return a<=b?o->next:o->alt;
        case JBR_IFEQ:return a==0?o->next:o->alt;
        case JBR_IFNE:return a!=0?o->next:o->alt;
        case JBR_IFLT:return a<0?o->next:o->alt;
        case JBR_IFGE:return a>=0?o->next:o->alt;
        case JBR_IFGT:return a>0?o->next:o->alt;
        case JBR_IFLE:return a<=0?o->next:o->alt;
        default:return JBR_END;
    }
    return o->next;
}
#endif
