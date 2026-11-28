#ifndef JARBOX_BLOCK_IR_H
#define JARBOX_BLOCK_IR_H
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include "jarbox_java_integer.h"

/* Immutable, pointer-free, original-PC block tape. Only local/stack effects
 * are lowered. All calls, memory accesses, faults and control transfers stay
 * in the ordinary interpreter. No executable memory, linking or JIT. */
enum { JBI_MAX_CODE=8192, JBI_MAX_SPANS=128, JBI_MAX_OPS=512,
       JBI_MAX_RUN=32, JBI_MIN_RUN=4, JBI_MAX_HANDLERS=64 };
typedef struct { uint16_t start,end,handler; } JbiHandler;
typedef struct { int32_t imm; int16_t slot; uint16_t local; uint8_t kind; } JbiOp;
typedef struct { uint16_t pc,end,first,count,need,peak; int16_t delta; uint16_t reserved; } JbiSpan;
/* Exact low-PC bucket: 0 empty, 1..128 unique span index + 1,
 * 255 collision. Immutable after plan publication; collision fallback
 * searches the original sorted span array. No cached VM object or value. */
typedef struct { uint8_t bucket[64]; uint32_t bytes; uint16_t spans,ops; JbiSpan span[]; } JbiPlan;
_Static_assert(sizeof(JbiSpan)%_Alignof(JbiOp)==0,"unaligned block tape");
static inline const JbiOp *jbi_ops(const JbiPlan *p) {return (const JbiOp *)(p->span+p->spans);}
static inline uint16_t jbi_u16(const uint8_t *p,int be) {
    uint16_t v; if(be)return (uint16_t)((uint16_t)p[0]<<8|p[1]);memcpy(&v,p,2);return v;
}
static inline int32_t jbi_i16(const uint8_t *p,int be) {
    uint16_t u=jbi_u16(p,be);return u>=32768u?(int32_t)u-65536:(int32_t)u;
}
static inline int32_t jbi_i32(const uint8_t *p,int be) {
    uint32_t v;if(be)v=(uint32_t)p[0]<<24|(uint32_t)p[1]<<16|(uint32_t)p[2]<<8|p[3];
    else memcpy(&v,p,4);
    return jarbox_java_i32(v);
}
static inline int32_t jbi_i8(uint8_t u) {return u>=128u?(int32_t)u-256:(int32_t)u;}
static inline int jbi_target(uint8_t *targets,unsigned size,unsigned pc,int32_t offset) {
    int64_t dst=(int64_t)pc+offset;if(dst<0||dst>=size)return 0;
    targets[dst]=1;return 1;
}
/* Full JVM instruction boundary decoder, including switch tables and wide.
 * Reject legacy subroutines, quickened/unknown opcodes and malformed widths.
 * Split at every branch/handler entry PC before lowering. */
static inline unsigned jbi_width(const uint8_t *c,unsigned size,unsigned pc,int be,uint8_t *targets) {
    unsigned o=c[pc],remain=size-pc,n=0;
    if(o<=0x0f)n=1;
    else if(o==0x10||o==0x12||(o>=0x15&&o<=0x19)||(o>=0x36&&o<=0x3a)||o==0xbc)n=2;
    else if(o==0x11||o==0x13||o==0x14||o==0x84||(o>=0xb2&&o<=0xb8)||o==0xbb||o==0xbd||o==0xc0||o==0xc1)n=3;
    else if((o>=0x1a&&o<=0x35)||(o>=0x3b&&o<=0x83)||(o>=0x85&&o<=0x98)||(o>=0xac&&o<=0xb1)||o==0xbe||o==0xbf||o==0xc2||o==0xc3)n=1;
    else if((o>=0x99&&o<=0xa7)||o==0xc6||o==0xc7) {
        if(remain<3||!jbi_target(targets,size,pc,jbi_i16(c+pc+1,be)))return 0;
        n=3;
    } else if(o==0xc8) {
        if(remain<5||!jbi_target(targets,size,pc,jbi_i32(c+pc+1,be)))return 0;
        n=5;
    } else if(o==0xaa||o==0xab) {
        unsigned pad=4-pc%4,head=o==0xaa?12:8,unit=o==0xaa?4:8;
        if(remain<pad+head)return 0;
        const uint8_t *p=c+pc+pad;
        if(!jbi_target(targets,size,pc,jbi_i32(p,be)))return 0;
        int64_t count=o==0xaa?(int64_t)jbi_i32(p+8,be)-jbi_i32(p+4,be)+1:jbi_i32(p+4,be);
        if(count<0||(o==0xaa&&!count)||(uint64_t)count>(remain-pad-head)/unit)return 0;
        for(unsigned i=0;i<(unsigned)count;++i)
            if(!jbi_target(targets,size,pc,jbi_i32(p+head+i*unit+(o==0xab?4:0),be)))return 0;
        n=pad+head+(unsigned)count*unit;
    } else if(o==0xb9||o==0xba)n=5;
    else if(o==0xc5)n=4;
    else if(o==0xc4) {
        if(remain<2)return 0;
        unsigned w=c[pc+1];
        if(w==0x84)n=6;
        else if((w>=0x15&&w<=0x19)||(w>=0x36&&w<=0x3a))n=4;
    }
    return n<=remain?n:0;
}
/* Lower to fixed entry-relative slots. Keep the exact interpreter write
 * widths: integer and reference lanes in StackEntry are independent. Do
 * NOT clear a stale rvalue or combine stores into wider writes. */
enum { JBI_NOP,JBI_ICONST,JBI_LCONST,JBI_NULL,JBI_ILOAD,JBI_RLOAD,JBI_LLOAD,
       JBI_ISTORE,JBI_RSTORE,JBI_LSTORE,JBI_IINC,JBI_DUP,JBI_DUP2,
       JBI_ADD,JBI_SUB,JBI_MUL,JBI_NEG,JBI_SHL,JBI_SHR,JBI_USHR,JBI_AND,JBI_OR,JBI_XOR,
       JBI_LADD,JBI_LSUB,JBI_LMUL,JBI_LNEG,JBI_LSHL,JBI_LSHR,JBI_LUSHR,JBI_LAND,JBI_LOR,JBI_LXOR,
       JBI_I2B,JBI_I2C,JBI_I2S,JBI_I2L,JBI_L2I,JBI_LCMP };
static inline int jbi_lower(const uint8_t *p,unsigned locals,int be,JbiOp *out,int *pop,int *push) {
    unsigned o=*p,local=0;int32_t imm=0;unsigned k=0;int a=0,b=0,localop=0;
    if(o==0xc4) {o=p[1];local=jbi_u16(p+2,be);if(o==0x84)imm=jbi_i16(p+4,be);}
    else if((o>=0x15&&o<=0x19)||(o>=0x36&&o<=0x3a)||o==0x84) {
        local=p[1];if(o==0x84)imm=jbi_i8(p[2]);
    } else if(o>=0x1a&&o<=0x2d) {local=(o-0x1a)%4;o=0x15+(o-0x1a)/4;}
    else if(o>=0x3b&&o<=0x4e) {local=(o-0x3b)%4;o=0x36+(o-0x3b)/4;}
    switch(o) {
        case 0x00:k=JBI_NOP;break;
        case 0x01:k=JBI_NULL;b=1;break;
        case 0x02:case 0x03:case 0x04:case 0x05:case 0x06:case 0x07:case 0x08:k=JBI_ICONST;imm=(int)o-3;b=1;break;
        case 0x09:case 0x0a:k=JBI_LCONST;imm=(int)o-9;b=2;break;
        case 0x10:k=JBI_ICONST;imm=jbi_i8(p[1]);b=1;break;
        case 0x11:k=JBI_ICONST;imm=jbi_i16(p+1,be);b=1;break;
        case 0x15:case 0x17:k=JBI_ILOAD;b=1;localop=1;break;
        case 0x16:case 0x18:k=JBI_LLOAD;b=2;localop=2;break;
        case 0x19:k=JBI_RLOAD;b=1;localop=1;break;
        case 0x36:case 0x38:k=JBI_ISTORE;a=1;localop=1;break;
        case 0x37:case 0x39:k=JBI_LSTORE;a=2;localop=2;break;
        case 0x3a:k=JBI_RSTORE;a=1;localop=1;break;
        case 0x84:k=JBI_IINC;localop=1;break;
        case 0x57:k=JBI_NOP;a=1;break;
        case 0x58:k=JBI_NOP;a=2;break;
        case 0x59:k=JBI_DUP;a=1;b=2;break;
        case 0x5c:k=JBI_DUP2;a=2;b=4;break;
#define JBI_BIN(raw,kind) case raw:k=kind;a=2;b=1;break
        JBI_BIN(0x60,JBI_ADD);JBI_BIN(0x64,JBI_SUB);JBI_BIN(0x68,JBI_MUL);
        JBI_BIN(0x78,JBI_SHL);JBI_BIN(0x7a,JBI_SHR);JBI_BIN(0x7c,JBI_USHR);
        JBI_BIN(0x7e,JBI_AND);JBI_BIN(0x80,JBI_OR);JBI_BIN(0x82,JBI_XOR);
#undef JBI_BIN
#define JBI_LBIN(raw,kind) case raw:k=kind;a=4;b=2;break
        JBI_LBIN(0x61,JBI_LADD);JBI_LBIN(0x65,JBI_LSUB);JBI_LBIN(0x69,JBI_LMUL);
        JBI_LBIN(0x7f,JBI_LAND);JBI_LBIN(0x81,JBI_LOR);JBI_LBIN(0x83,JBI_LXOR);
#undef JBI_LBIN
        case 0x74:k=JBI_NEG;a=b=1;break;
        case 0x75:k=JBI_LNEG;a=b=2;break;
        case 0x79:k=JBI_LSHL;a=3;b=2;break;
        case 0x7b:k=JBI_LSHR;a=3;b=2;break;
        case 0x7d:k=JBI_LUSHR;a=3;b=2;break;
        case 0x91:k=JBI_I2B;a=b=1;break;
        case 0x92:k=JBI_I2C;a=b=1;break;
        case 0x93:k=JBI_I2S;a=b=1;break;
        case 0x85:k=JBI_I2L;a=1;b=2;break;
        case 0x88:k=JBI_L2I;a=2;b=1;break;
        case 0x94:k=JBI_LCMP;a=4;b=1;break;
        default:return 0;
    }
    if(localop&&(local>=locals||(unsigned)localop>locals-local))return 0;
    *out=(JbiOp){.kind=(uint8_t)k,.local=(uint16_t)local,.imm=imm};*pop=a;*push=b;return 1;
}
static inline JbiPlan *jbi_build(const uint8_t *c,unsigned size,unsigned locals,unsigned maxstack,
        const JbiHandler *handlers,unsigned nh,int be) {
    if(!c||size<5||size>JBI_MAX_CODE||locals>32767||maxstack>32767||nh>JBI_MAX_HANDLERS||(nh&&!handlers))return NULL;
    uint8_t starts[JBI_MAX_CODE]={0},targets[JBI_MAX_CODE]={0};
    for(unsigned pc=0;pc<size;) {
        starts[pc]=1;unsigned w=jbi_width(c,size,pc,be,targets);if(!w)return NULL;pc+=w;
    }
    for(unsigned i=0;i<nh;++i) {
        JbiHandler h=handlers[i];if(h.start>=h.end||h.end>size||h.handler>=size)return NULL;
        targets[h.start]=targets[h.handler]=1;if(h.end<size)targets[h.end]=1;
    }
    for(unsigned pc=0;pc<size;++pc)if(targets[pc]&&!starts[pc])return NULL;
    JbiSpan spans[JBI_MAX_SPANS];JbiOp ops[JBI_MAX_OPS],pending[JBI_MAX_RUN];
    unsigned ns=0,no=0,n=0,start=0;int depth=0,need=0,peak=0;
    uint8_t bucket[64]={0};
    for(unsigned pc=0;pc<=size;) {
        JbiOp op;int pop=0,push=0;
        unsigned w=pc<size?jbi_width(c,size,pc,be,targets):0;
        int pure=pc<size&&w&&jbi_lower(c+pc,locals,be,&op,&pop,&push);
        if(n&&(!pure||targets[pc]||n==JBI_MAX_RUN)) {
            if(n>=JBI_MIN_RUN&&pc<size&&(unsigned)(need+peak)<=maxstack) {
                if(ns==JBI_MAX_SPANS||n>JBI_MAX_OPS-no)return NULL;
                spans[ns++]=(JbiSpan){(uint16_t)start,(uint16_t)pc,(uint16_t)no,(uint16_t)n,(uint16_t)need,(uint16_t)peak,(int16_t)depth,0};
                memcpy(ops+no,pending,n*sizeof(*ops));no+=n;
                unsigned slot=start&63u;bucket[slot]=bucket[slot]?255:(uint8_t)ns;
            }
            n=0;depth=need=peak=0;
        }
        if(pc==size)break;
        if(pure) {
            if(!n)start=pc;
            depth-=pop;if(-depth>need)need=-depth;op.slot=(int16_t)depth;
            pending[n++]=op;depth+=push;if(depth>peak)peak=depth;
        }
        pc+=w;
    }
    if(!ns)return NULL;
    size_t bytes=sizeof(JbiPlan)+ns*sizeof(JbiSpan)+no*sizeof(JbiOp);
    JbiPlan *p=malloc(bytes);if(!p)return NULL;
    p->bytes=(uint32_t)bytes;p->spans=(uint16_t)ns;p->ops=(uint16_t)no;
    memcpy(p->bucket,bucket,sizeof bucket);
    memcpy(p->span,spans,ns*sizeof(*spans));memcpy((void *)jbi_ops(p),ops,no*sizeof(*ops));return p;
}
static inline const JbiSpan *jbi_find(const JbiPlan *p,unsigned pc) {
    if(!p||pc>=JBI_MAX_CODE)return NULL;
    unsigned slot=p->bucket[pc&63u];
    if(!slot)return NULL;
    if(slot!=255){
        const JbiSpan *s=p->span+(slot-1);
        return s->pc==pc?s:NULL;
    }
    unsigned l=0,r=p->spans;
    while(l<r){unsigned m=l+(r-l)/2;if(p->span[m].pc<pc)l=m+1;else r=m;}
    return l<p->spans&&p->span[l].pc==pc?p->span+l:NULL;
}
/* No safepoint within a span: no original opcode here could call or block.
 * Preserve all existing stack writes, including stale reference lanes. */
static inline void jbi_execute(const JbiPlan *p,const JbiSpan *s,StackEntry *entry,StackEntry *locals) {
    const JbiOp *ops=jbi_ops(p)+s->first;
    for(unsigned i=0;i<s->count;++i) {
        const JbiOp *o=ops+i;StackEntry *d=entry+o->slot;
        switch(o->kind) {
            case JBI_NOP:break;
            case JBI_ICONST:d->ivalue=o->imm;break;
            case JBI_LCONST:d->lvalue=o->imm;break;
            case JBI_NULL:d->rvalue=NULL;break;
            case JBI_ILOAD:d->ivalue=locals[o->local].ivalue;break;
            case JBI_LLOAD:d->lvalue=locals[o->local].lvalue;break;
            case JBI_RLOAD:d->rvalue=locals[o->local].rvalue;break;
            case JBI_ISTORE:locals[o->local].ivalue=d->ivalue;break;
            case JBI_LSTORE:locals[o->local].lvalue=d->lvalue;break;
            case JBI_RSTORE:locals[o->local].rvalue=d->rvalue;break;
            case JBI_IINC:locals[o->local].ivalue=jarbox_java_iadd(locals[o->local].ivalue,o->imm);break;
            case JBI_DUP:d[1]=d[0];break;
            case JBI_DUP2:d[2]=d[0];d[3]=d[1];break;
            case JBI_ADD:d->ivalue=jarbox_java_iadd(d->ivalue,d[1].ivalue);break;
            case JBI_SUB:d->ivalue=jarbox_java_isub(d->ivalue,d[1].ivalue);break;
            case JBI_MUL:d->ivalue=jarbox_java_imul(d->ivalue,d[1].ivalue);break;
            case JBI_NEG:d->ivalue=jarbox_java_isub(0,d->ivalue);break;
            case JBI_SHL:d->ivalue=jarbox_java_ishl(d->ivalue,d[1].ivalue);break;
            case JBI_SHR:d->ivalue=jarbox_java_ishr(d->ivalue,d[1].ivalue);break;
            case JBI_USHR:d->uivalue>>=d[1].uivalue&31u;break;
            case JBI_AND:d->ivalue&=d[1].ivalue;break;
            case JBI_OR:d->ivalue|=d[1].ivalue;break;
            case JBI_XOR:d->ivalue^=d[1].ivalue;break;
            case JBI_LADD:d->lvalue=jarbox_java_ladd(d->lvalue,d[2].lvalue);break;
            case JBI_LSUB:d->lvalue=jarbox_java_lsub(d->lvalue,d[2].lvalue);break;
            case JBI_LMUL:d->lvalue=jarbox_java_lmul(d->lvalue,d[2].lvalue);break;
            case JBI_LNEG:d->lvalue=jarbox_java_lsub(0,d->lvalue);break;
            case JBI_LSHL:d->lvalue=jarbox_java_lshl(d->lvalue,d[2].ivalue);break;
            case JBI_LSHR:d->lvalue=jarbox_java_lshr(d->lvalue,d[2].ivalue);break;
            case JBI_LUSHR:d->ulvalue>>=d[2].uivalue&63u;break;
            case JBI_LAND:d->lvalue&=d[2].lvalue;break;
            case JBI_LOR:d->lvalue|=d[2].lvalue;break;
            case JBI_LXOR:d->lvalue^=d[2].lvalue;break;
            case JBI_I2B:d->ivalue=jbi_i8((uint8_t)d->uivalue);break;
            case JBI_I2C:d->ivalue=(uint16_t)d->uivalue;break;
            case JBI_I2S:{uint16_t u=(uint16_t)d->uivalue;d->ivalue=u>=32768u?(int32_t)u-65536:(int32_t)u;break;}
            case JBI_I2L:d->lvalue=(int64_t)d->ivalue;break;
            case JBI_L2I:d->ivalue=jarbox_java_i32((uint32_t)d->ulvalue);break;
            case JBI_LCMP:d->ivalue=(d->lvalue>d[2].lvalue)-(d->lvalue<d[2].lvalue);break;
        }
    }
}
#endif
