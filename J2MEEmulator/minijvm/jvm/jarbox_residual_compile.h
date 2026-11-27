#ifndef JARBOX_RESIDUAL_COMPILE_H
#define JARBOX_RESIDUAL_COMPILE_H
#include <stdlib.h>
#include <string.h>
#include "jarbox_residual_plan.h"

// Bounded compiler for the observed category-1 opcode subset. The caller
// supplies verified symbolic CP kinds and the *converted* immutable code.
// Merely accepting a shape does not authorize eliminating a graphics sink.
enum { JBR_MAX_NODES=1024, JBR_MAX_CODE=4096, JBR_MAX_DEPTH=12 };
enum { JBR_CP_REJECT, JBR_CP_INT, JBR_CP_REF, JBR_CP_INT2, JBR_CP_DRAW };
typedef int (*JarBoxResidualCPKind)(void *,unsigned,unsigned);
typedef struct {
    JarBoxResidualOp op;
    uint32_t uses,defs,live;
    uint16_t refs;
    uint8_t raw,seen,depth,initialized,reachable;
} JbrCompileNode;
typedef struct {
    JbrCompileNode nodes[JBR_MAX_NODES];
    uint16_t at[JBR_MAX_CODE], remap[JBR_MAX_NODES];
} JbrCompileScratch;
typedef struct { unsigned depth,refs,initialized; } JbrTypes;
static inline uint16_t jbr_u16(const unsigned char *p) {uint16_t v;memcpy(&v,p,2);return v;}
static inline int16_t jbr_i16(const unsigned char *p) {int16_t v;memcpy(&v,p,2);return v;}
static inline int jbr_pop(JbrTypes *t,int ref) {
    if(!t->depth)return -1;
    unsigned d=--t->depth,b=1u<<d;
    if(!!(t->refs&b)!=ref)return -1;
    t->refs&=~b;return (ref?16:4)+(int)d;
}
static inline int jbr_push(JbrTypes *t,int ref) {
    if(t->depth>=JBR_MAX_DEPTH)return -1;
    unsigned d=t->depth++;
    if(ref)t->refs|=1u<<d;
    return (ref?16:4)+(int)d;
}
static inline unsigned jbr_raw_size(unsigned o) {
    switch(o) {
        case 0x10:return 2;
        case 0x11:case 0x84:case 0xb2:case 0xb3:case 0xb8:case 0xb6:
        case 0x9f:case 0xa0:case 0xa2:case 0xa7:return 3;
        case 0x02:case 0x03:case 0x04:case 0x05:case 0x06:case 0x07:case 0x08:
        case 0x1b:case 0x1c:case 0x1d:case 0x2a:case 0x3c:case 0x3d:case 0x3e:
        case 0x59:case 0x60:case 0x64:case 0x68:case 0x7e:case 0x7a:
        case 0x6c:case 0x70:case 0x34:case 0xb1:return 1;
        default:return 0;
    }
}
static inline int jbr_merge(JbrCompileNode *n,const JbrTypes *t,int *changed) {
    if(!n->seen) {n->seen=1;n->depth=t->depth;n->refs=t->refs;n->initialized=t->initialized;*changed=1;return 1;}
    if(n->depth!=t->depth||n->refs!=t->refs)return 0;
    unsigned v=n->initialized&t->initialized;
    if(v!=n->initialized){n->initialized=v;*changed=1;}
    return 1;
}
static inline void jbr_empty(JbrCompileNode *n) {
    n->op.kind=JBR_NOP;n->op.a=n->op.b=n->op.dst=JBR_NONE;
    n->op.alt=JBR_END;n->op.length=0;n->op.imm=0;n->uses=n->defs=0;
}
static inline unsigned jbr_chase(const JbrCompileNode *n,unsigned count,unsigned at) {
    for(unsigned k=0;k<count;k++) {
        if(at>=count)return JBR_END;
        if(n[at].op.kind!=JBR_NOP)return at;
        at=n[at].op.next;
    }
    return JBR_END; // reject an unproved empty cycle, never erase nontermination
}
// Return emitted count, zero on any unsupported/malformed input/OOM. No
// partial plan is published. All call/array/division and static reads/writes
// remain roots. draw_effects=1 retains receiver/source and original call;
// the dummy primitive args are valid solely for the trusted sink fixture.
static inline unsigned jbr_compile(const unsigned char *code,unsigned size,
    JarBoxResidualCPKind cp,void *ctx,int draw_effects,JarBoxResidualOp *out,unsigned capacity) {
    if(!code||!cp||!out||!size||size>JBR_MAX_CODE||!capacity)return 0;
    JbrCompileScratch *sc=calloc(1,sizeof(*sc));if(!sc)return 0;
    JbrCompileNode *n=sc->nodes;unsigned count=0,result=0;
    memset(sc->at,0xff,sizeof(sc->at));memset(sc->remap,0xff,sizeof(sc->remap));
    for(unsigned p=0;p<size;) {
        unsigned len=jbr_raw_size(code[p]);if(!len||len>size-p||count==JBR_MAX_NODES)goto done;
        sc->at[p]=count;n[count].raw=code[p];n[count].op.pc=p;
        count++;p+=len;
    }
    for(unsigned i=0;i<count;i++) {
        JarBoxResidualOp *o=&n[i].op;unsigned raw=n[i].raw;
        o->next=i+1<count?i+1:JBR_END;o->alt=JBR_END;
        if(raw==0x9f||raw==0xa0||raw==0xa2||raw==0xa7) {
            int p=(int)o->pc+jbr_i16(code+o->pc+1);
            if(p<0||(unsigned)p>=size||sc->at[p]==JBR_END)goto done;
            if(raw!=0xa7)o->alt=o->next;
            o->next=sc->at[p];
        } else if(raw==0xb1)o->next=JBR_END;
        if(raw!=0xb1&&o->next==JBR_END)goto done;
        if((raw==0x9f||raw==0xa0||raw==0xa2)&&o->alt==JBR_END)goto done;
    }
    n[0].seen=1;n[0].initialized=1;
    // Types and definite initialization converge monotonically at CFG merges.
    for(unsigned pass=0;;pass++) {
        int changed=0;if(pass>count*4u)goto done;
        for(unsigned i=0;i<count;i++) {
            JbrCompileNode *v=n+i;if(!v->seen)continue;
            JarBoxResidualOp *o=&v->op;unsigned raw=v->raw,pc0=o->pc;
            JbrTypes t={v->depth,v->refs,v->initialized};
            int a=JBR_NONE,b=JBR_NONE,d=JBR_NONE,kind=JBR_NOP,imm=0,len=0;
            if(raw>=0x02&&raw<=0x08){kind=JBR_CONST;imm=(int)raw-3;d=jbr_push(&t,0);}
            else if(raw==0x10||raw==0x11){kind=JBR_CONST;imm=raw==0x10?(int8_t)code[pc0+1]:jbr_i16(code+pc0+1);d=jbr_push(&t,0);}
            else if(raw>=0x1b&&raw<=0x1d){kind=JBR_MOVE;a=raw-0x1a;if(!(t.initialized&(1u<<a)))goto done;d=jbr_push(&t,0);}
            else if(raw>=0x3c&&raw<=0x3e){kind=JBR_MOVE;a=jbr_pop(&t,0);d=raw-0x3b;t.initialized|=1u<<d;}
            else if(raw==0x2a){kind=JBR_MOVE;a=0;d=jbr_push(&t,1);}
            else if(raw==0x59){if(!t.depth||(t.refs&(1u<<(t.depth-1))))goto done;kind=JBR_MOVE;a=4+t.depth-1;d=jbr_push(&t,0);}
            else if(raw==0x84){kind=JBR_INC;a=d=code[pc0+1];if(a<1||a>3||!(t.initialized&(1u<<a)))goto done;imm=(int8_t)code[pc0+2];}
            else if(raw==0xb2||raw==0xb3||raw==0xb8||raw==0xb6){
                int typ=cp(ctx,raw,jbr_u16(code+pc0+1));kind=JBR_EFFECT;imm=raw;len=3;
                if(raw==0xb2){if(typ!=JBR_CP_INT&&typ!=JBR_CP_REF)goto done;d=jbr_push(&t,typ==JBR_CP_REF);}
                else if(raw==0xb3){if(typ!=JBR_CP_INT)goto done;a=jbr_pop(&t,0);}
                else if(raw==0xb8){if(typ!=JBR_CP_INT2)goto done;b=jbr_pop(&t,0);a=jbr_pop(&t,0);d=jbr_push(&t,0);}
                else {if(typ!=JBR_CP_DRAW)goto done;for(unsigned j=0;j<8;j++)if(jbr_pop(&t,0)<0)goto done;
                    b=jbr_pop(&t,1);a=jbr_pop(&t,1);if(a<0||b<0)goto done;
                    if(!draw_effects){kind=JBR_NOP;a=b=JBR_NONE;imm=len=0;}}
            }
            else if(raw==0xa7)kind=JBR_NOP;
            else if(raw==0xb1){if(t.depth)goto done;kind=JBR_EFFECT;imm=raw;len=1;}
            else {
                b=jbr_pop(&t,0);a=jbr_pop(&t,raw==0x34);
                if(raw==0x9f||raw==0xa0||raw==0xa2)kind=raw==0x9f?JBR_IF_ICMPEQ:raw==0xa0?JBR_IF_ICMPNE:JBR_IF_ICMPGE;
                else {d=jbr_push(&t,0);switch(raw){
                    case 0x60:kind=JBR_IADD;break;case 0x64:kind=JBR_ISUB;break;
                    case 0x68:kind=JBR_IMUL;break;case 0x7e:kind=JBR_IAND;break;case 0x7a:kind=JBR_ISHR;break;
                    case 0x34:case 0x6c:case 0x70:kind=JBR_EFFECT;imm=raw;len=1;break;
                    default:goto done;}}
            }
            if(a<0||b<0||d<0)goto done;
            o->kind=kind;o->a=a;o->b=b;o->dst=d;o->imm=imm;o->length=len;
            v->uses=(a!=JBR_NONE?1u<<a:0)|(b!=JBR_NONE?1u<<b:0);v->defs=d!=JBR_NONE?1u<<d:0;
            if(o->next!=JBR_END&&!jbr_merge(n+o->next,&t,&changed))goto done;
            if(o->alt!=JBR_END&&!jbr_merge(n+o->alt,&t,&changed))goto done;
        }
        if(!changed)break;
    }
    for(unsigned i=0;i<count;i++)if(!n[i].seen)goto done;
    // Backward liveness, erase dead pure definitions, thread empty edges.
    for(unsigned pass=0;;pass++) {
        int altered=0;if(pass>count*2u)goto done;
        for(unsigned i=0;i<count;i++)n[i].live=0;
        for(unsigned iter=0;;iter++) {
            int changed=0;if(iter>count*32u)goto done;
            for(unsigned i=count;i--;) {
                JarBoxResidualOp *o=&n[i].op;
                uint32_t live=(o->next==JBR_END?0:n[o->next].live)|(o->alt==JBR_END?0:n[o->alt].live);
                live=n[i].uses|(live&~n[i].defs);
                if(live!=n[i].live){n[i].live=live;changed=1;}
            }
            if(!changed)break;
        }
        for(unsigned i=0;i<count;i++) {
            JarBoxResidualOp *o=&n[i].op;
            uint32_t live=(o->next==JBR_END?0:n[o->next].live)|(o->alt==JBR_END?0:n[o->alt].live);
            if(o->kind!=JBR_EFFECT&&n[i].defs&&!(n[i].defs&live)){jbr_empty(n+i);altered=1;}
        }
        for(unsigned i=0;i<count;i++) {
            JarBoxResidualOp *o=&n[i].op;
            if(o->next!=JBR_END){unsigned q=jbr_chase(n,count,o->next);if(q==JBR_END)goto done;if(q!=o->next){o->next=q;altered=1;}}
            if(o->alt!=JBR_END){unsigned q=jbr_chase(n,count,o->alt);if(q==JBR_END)goto done;if(q!=o->alt){o->alt=q;altered=1;}}
            if(o->alt!=JBR_END&&o->next==o->alt){jbr_empty(n+i);altered=1;}
        }
        if(!altered)break;
    }
    unsigned entry=jbr_chase(n,count,0);if(entry==JBR_END)goto done;n[entry].reachable=1;
    for(unsigned pass=0;;pass++) {
        int changed=0;if(pass>count)goto done;
        for(unsigned i=0;i<count;i++)if(n[i].reachable){
            unsigned a=n[i].op.next,b=n[i].op.alt;
            if(a!=JBR_END&&!n[a].reachable){n[a].reachable=1;changed=1;}
            if(b!=JBR_END&&!n[b].reachable){n[b].reachable=1;changed=1;}
        }if(!changed)break;
    }
    unsigned total=1;sc->remap[entry]=0;
    for(unsigned i=0;i<count;i++){
        if(!n[i].reachable){if(n[i].op.kind==JBR_EFFECT)goto done;continue;}
        if(i!=entry)sc->remap[i]=total++;
    }
    if(total>capacity)goto done;
    for(unsigned i=0;i<count;i++)if(n[i].reachable){JarBoxResidualOp o=n[i].op;
        if(o.next!=JBR_END)o.next=sc->remap[o.next];
        if(o.alt!=JBR_END)o.alt=sc->remap[o.alt];
        out[sc->remap[i]]=o;}
    result=total;
done:
    free(sc);return result;
}
#endif
