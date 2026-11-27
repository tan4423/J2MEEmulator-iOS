#ifndef JARBOX_RESIDUAL_COMPILE_H
#define JARBOX_RESIDUAL_COMPILE_H
#include <stdlib.h>
#include <string.h>
#include "jarbox_residual_plan.h"

// Bounded compiler for the observed category-1 opcode subset. The caller
// supplies verified symbolic CP kinds and the *converted* immutable code.
// Merely accepting a shape does not authorize eliminating a graphics sink.
enum { JBR_MAX_NODES=1024, JBR_MAX_CODE=4096, JBR_MAX_DEPTH=12 };
enum { JBR_CP_REJECT, JBR_CP_INT, JBR_CP_REF, JBR_CP_INT2, JBR_CP_DRAW, JBR_CP_PLAIN_INT, JBR_CP_DRAW_IMAGE, JBR_CP_DRAW_RECT, JBR_CP_LITERAL_INT,JBR_CP_CAST };
/* Packed descriptor shape: flag, result (0 void,1 int,2 ref), argc, refmask.
   All arguments are category 1; no generic call may be erased. */
enum { JBR_CP_CALL_FLAG=1<<20 };
static inline int jbr_call_shape(unsigned argc,unsigned refs,unsigned result){
    return argc<=12&&result<=2&&!(refs>>argc)?(int)(JBR_CP_CALL_FLAG|(result<<16)|(argc<<12)|refs):0;
}
static inline int jbr_draw_shape(int typ){
    if(typ==JBR_CP_DRAW)return jbr_call_shape(10,3,0);
    if(typ==JBR_CP_DRAW_IMAGE)return jbr_call_shape(5,3,0);
    if(typ==JBR_CP_DRAW_RECT)return jbr_call_shape(5,1,0);
    return 0;
}
typedef int (*JarBoxResidualCPKind)(void *,unsigned,unsigned);
typedef struct {
    JarBoxResidualOp op;
    uint32_t uses,defs,live;
    uint16_t refs;
    uint8_t raw,seen,depth,initialized,reachable,plain_read,local_refs,closed_start,closed_end;
} JbrCompileNode;
typedef struct {
    JbrCompileNode nodes[JBR_MAX_NODES];
    uint16_t at[JBR_MAX_CODE], remap[JBR_MAX_NODES];
} JbrCompileScratch;
typedef struct { unsigned depth,refs,initialized,local_refs; } JbrTypes;
static inline int jbr_raw_branch(unsigned raw){return (raw>=0x99&&raw<=0xa6)||raw==0xc6||raw==0xc7;}
static inline unsigned jbr_local(unsigned n){return n==4?JBR_LOCAL4:n;}
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
        case 0x10:case 0x15:case 0x36:case 0x12:case 0x19:case 0x3a:return 2;
        case 0x11:case 0x84:case 0xb2:case 0xb3:case 0xb8:case 0xb6:case 0xb4:case 0xc0:case 0x13:
        case 0x99:case 0x9a:case 0x9b:case 0x9c:case 0x9d:case 0x9e:
        case 0x9f:case 0xa0:case 0xa1:case 0xa2:case 0xa3:case 0xa4:case 0xa5:case 0xa6:case 0xa7:case 0xc6:case 0xc7:return 3;
        case 0x01:case 0x2d:case 0x4e:case 0x2c:case 0x4d:case 0x2e:case 0x32:case 0x74:case 0x78:
        case 0x02:case 0x03:case 0x04:case 0x05:case 0x06:case 0x07:case 0x08:
        case 0x1b:case 0x1c:case 0x1d:case 0x2a:case 0x3c:case 0x3d:case 0x3e:
        case 0x59:case 0x60:case 0x64:case 0x68:case 0x7e:case 0x7a:
        case 0x6c:case 0x70:case 0x34:case 0xb1:return 1;
        default:return 0;
    }
}
static inline int jbr_merge(JbrCompileNode *n,const JbrTypes *t,int *changed) {
    if(!n->seen) {n->seen=1;n->depth=t->depth;n->refs=t->refs;n->initialized=t->initialized;n->local_refs=t->local_refs;*changed=1;return 1;}
    if(n->depth!=t->depth||n->refs!=t->refs)return 0;
    unsigned v=n->initialized&t->initialized&~(n->local_refs^t->local_refs);
    unsigned refs=n->local_refs&v;
    if(v!=n->initialized||refs!=n->local_refs){n->initialized=v;n->local_refs=refs;*changed=1;}
    return 1;
}
static inline void jbr_empty(JbrCompileNode *n) {
    n->op.kind=JBR_NOP;n->op.a=n->op.b=n->op.dst=JBR_NONE;
    n->op.alt=JBR_END;n->op.length=0;n->op.checkpoint=0;n->op.imm=0;n->uses=n->defs=0;
}
static inline unsigned jbr_chase(const JbrCompileNode *n,unsigned count,unsigned at) {
    for(unsigned k=0;k<count;k++) {
        if(at>=count)return JBR_END;
        if(n[at].op.kind!=JBR_NOP)return at;
        at=n[at].op.next;
    }
    return JBR_END; // reject an unproved empty cycle, never erase nontermination
}
// Every removed draw must be in a closed, single-entry linear argument
// region. No helper calls, external writes, or branches are allowed between
// checkpoint and the draw. Array/arithmetic faults remain original effects.
// This proves control shape only, NOT absence of class-init or sink effects.
static inline int jbr_closed_draw_regions(const JbrCompileNode *n,unsigned count) {
    uint16_t incoming[JBR_MAX_NODES]={0};
    if(!count||count>JBR_MAX_NODES)return 0;
    for(unsigned i=0;i<count;i++){
        unsigned a=n[i].op.next,b=n[i].op.alt;
        if(a!=JBR_END){if(a>=count)return 0;++incoming[a];}
        if(b!=JBR_END){if(b>=count)return 0;++incoming[b];}
    }
    unsigned active=0,draws=0;
    for(unsigned i=0;i<count;i++){
        unsigned raw=n[i].raw;
        if(raw==0x2a){if(active)return 0;active=1;continue;}
        if(!active){if(raw==0xb6)return 0;continue;}
        if(!i||incoming[i]!=1||n[i-1].op.next!=i||n[i-1].op.alt!=JBR_END)return 0;
        if(raw==0xb6){active=0;++draws;continue;}
        if(raw==0xb8||raw==0xb3||raw==0xb1||raw==0xa7||
           jbr_raw_branch(raw))return 0;
    }
    return !active&&draws>0;
}
// Policy 5 permits retained calls between closed draw regions. Only a
// straight-line argument island beginning at aload_0 is removable; an
// uncertified invocation is a normal effect, never silently omitted.
// No state call, field-instance read, store, branch or helper can be inside.
static inline int jbr_find_closed_draws(JbrCompileNode *n,unsigned count,
        const unsigned char *code,JarBoxResidualCPKind cp,void *ctx) {
    uint16_t incoming[JBR_MAX_NODES]={0};
    for(unsigned i=0;i<count;i++){
        if(n[i].op.next!=JBR_END)++incoming[n[i].op.next];
        if(n[i].op.alt!=JBR_END)++incoming[n[i].op.alt];
    }
    unsigned found=0;
    for(unsigned i=0;i<count;i++)if(n[i].raw==0x2a){
        for(unsigned j=i+1;j<count;j++){
            unsigned raw=n[j].raw;
            if(incoming[j]!=1||n[j-1].op.next!=j||n[j-1].op.alt!=JBR_END)break;
            if(raw==0xb6){
                if(jbr_draw_shape(cp(ctx,raw,jbr_u16(code+n[j].op.pc+1)))){
                    n[i].closed_start=1;n[j].closed_end=1;++found;
                }
                break;
            }
            if(!((raw>=0x02&&raw<=0x08)||raw==0x10||raw==0x11||raw==0x12||raw==0x13||
                raw==0x15||(raw>=0x1b&&raw<=0x1d)||raw==0x2c||raw==0x2d||raw==0x19||
                raw==0xb2||raw==0x60||raw==0x64||raw==0x68||raw==0x74||
                raw==0x78||raw==0x7a||raw==0x7e||raw==0x6c||raw==0x70))break;
        }
    }
    return found!=0;
}
static inline int jbr_wide_pop(JbrTypes *t,unsigned argc,unsigned refs,uint32_t *uses){
    if(argc>12||argc>t->depth||refs>>argc)return 0;
    for(unsigned i=argc;i--;){
        int a=jbr_pop(t,(refs>>i)&1u);if(a<0)return 0;*uses|=1u<<a;
    }
    return 1;
}
// Return emitted count, zero on any unsupported/malformed input/OOM. No
// partial plan is published. All call/array/division and static reads/writes
// remain roots. draw_effects=1 retains receiver/source and original call;
// the dummy primitive args are valid solely for the trusted sink fixture.
static inline unsigned jbr_compile(const unsigned char *code,unsigned size,
    JarBoxResidualCPKind cp,void *ctx,int draw_effects,JarBoxResidualOp *out,unsigned capacity) {
    if(!code||!cp||!out||!size||size>JBR_MAX_CODE||!capacity||draw_effects<0||draw_effects>5)return 0;
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
        if(jbr_raw_branch(raw)||raw==0xa7) {
            int p=(int)o->pc+jbr_i16(code+o->pc+1);
            if(p<0||(unsigned)p>=size||sc->at[p]==JBR_END)goto done;
            if(raw!=0xa7)o->alt=o->next;
            o->next=sc->at[p];
        } else if(raw==0xb1)o->next=JBR_END;
        if(raw!=0xb1&&o->next==JBR_END)goto done;
        if(jbr_raw_branch(raw)&&o->alt==JBR_END)goto done;
    }
    if((draw_effects==3||draw_effects==4)&&!jbr_closed_draw_regions(n,count))goto done;
    if(draw_effects==5&&!jbr_find_closed_draws(n,count,code,cp,ctx))goto done;
    n[0].seen=1;n[0].initialized=1;
    // Types and definite initialization converge monotonically at CFG merges.
    for(unsigned pass=0;;pass++) {
        int changed=0;if(pass>count*4u)goto done;
        for(unsigned i=0;i<count;i++) {
            JbrCompileNode *v=n+i;if(!v->seen)continue;
            JarBoxResidualOp *o=&v->op;unsigned raw=v->raw,pc0=o->pc;
            JbrTypes t={v->depth,v->refs,v->initialized,v->local_refs};
            if(draw_effects<5&&(raw==0x12||raw==0x13||raw==0x19||raw==0x3a||raw==0x2c||raw==0x4d||raw==0x2e||raw==0x32||raw==0x74||raw==0x78||raw==0xb4||raw==0xc0||raw==0xa5||raw==0xa6||raw==0xc6||raw==0xc7))goto done;
            if(draw_effects<4&&(raw==0x01||raw==0x2d||raw==0x4e||raw==0x15||raw==0x36||
                (jbr_raw_branch(raw)&&raw!=0x9f&&raw!=0xa0&&raw!=0xa2)))goto done;
            int a=JBR_NONE,b=JBR_NONE,d=JBR_NONE,kind=JBR_NOP,imm=0,len=0;
            uint32_t wide_uses=0;
            if(raw>=0x02&&raw<=0x08){kind=JBR_CONST;imm=(int)raw-3;d=jbr_push(&t,0);}
            else if(raw==0x10||raw==0x11){kind=JBR_CONST;imm=raw==0x10?(int8_t)code[pc0+1]:jbr_i16(code+pc0+1);d=jbr_push(&t,0);}
            else if(raw==0x01){kind=JBR_NULL;d=jbr_push(&t,1);}
            else if((raw>=0x1b&&raw<=0x1d)||raw==0x15){
                unsigned l=raw==0x15?code[pc0+1]:raw-0x1a;
                if(l<1||l>4||!(t.initialized&(1u<<l))||(t.local_refs&(1u<<l)))goto done;
                kind=JBR_MOVE;a=jbr_local(l);d=jbr_push(&t,0);
            }
            else if((raw>=0x3c&&raw<=0x3e)||raw==0x36){
                unsigned l=raw==0x36?code[pc0+1]:raw-0x3b;
                if(l<1||l>4)goto done;
                kind=JBR_MOVE;a=jbr_pop(&t,0);d=jbr_local(l);
                t.initialized|=1u<<l;t.local_refs&=~(1u<<l);
            }
            else if(raw==0x2d||raw==0x2c||raw==0x19){
                unsigned l=raw==0x19?code[pc0+1]:raw-0x2a;
                if(l<2||l>4||!(t.initialized&(1u<<l))||!(t.local_refs&(1u<<l)))goto done;
                kind=JBR_MOVE_REF;a=jbr_local(l);d=jbr_push(&t,1);
            }
            else if(raw==0x4e||raw==0x4d||raw==0x3a){
                unsigned l=raw==0x3a?code[pc0+1]:raw-0x4b;
                if(l<2||l>4)goto done;
                kind=JBR_MOVE_REF;a=jbr_pop(&t,1);d=jbr_local(l);
                t.initialized|=1u<<l;t.local_refs|=1u<<l;
            }
            else if(raw==0x2a){
                // Resume is allowed only before the first operand of a draw
                // block, with the ordinary locals definitely initialized.
                // This narrow contract rejects unsupported stack shapes.
                if((draw_effects>=2&&draw_effects<5)||(draw_effects==5&&v->closed_start)){
                    if(t.depth || (draw_effects==5?0:draw_effects==4?(t.initialized&6u)!=6u:(t.initialized&14u)!=14u))goto done;
                    o->checkpoint=1;
                }
                kind=JBR_MOVE;a=0;d=jbr_push(&t,1);
            }
            else if(raw==0x59){if(!t.depth)goto done;int ref=!!(t.refs&(1u<<(t.depth-1)));if(ref&&draw_effects!=5)goto done;kind=JBR_MOVE;a=(ref?16:4)+t.depth-1;d=jbr_push(&t,ref);}
            else if(raw==0x84){unsigned l=code[pc0+1];kind=JBR_INC;if(l<1||l>(draw_effects>=4?4u:3u)||!(t.initialized&(1u<<l))||(t.local_refs&(1u<<l)))goto done;a=d=jbr_local(l);imm=(int8_t)code[pc0+2];}
            else if(draw_effects==5&&(raw==0xb6||raw==0xb8||raw==0xb4||raw==0xc0||
                         raw==0x2e||raw==0x32||raw==0x12||raw==0x13)){
                unsigned argc=0,refs=0,result_type=0;
                int typ=0;
                if(raw==0xb6||raw==0xb8){
                    typ=cp(ctx,raw,jbr_u16(code+pc0+1));
                    int shape=jbr_draw_shape(typ);
                    if(!shape)shape=typ;
                    if(!(shape&JBR_CP_CALL_FLAG))goto done;
                    argc=((unsigned)shape>>12)&15u;refs=(unsigned)shape&4095u;
                    result_type=((unsigned)shape>>16)&3u;
                    if(result_type>2||(raw==0xb6&&(!argc||!(refs&1u))))goto done;
                } else if(raw==0xb4){
                    typ=cp(ctx,raw,jbr_u16(code+pc0+1));
                    if(typ!=JBR_CP_INT&&typ!=JBR_CP_REF)goto done;
                    argc=refs=1;result_type=typ==JBR_CP_REF?2:1;
                } else if(raw==0xc0){
                    if(cp(ctx,raw,jbr_u16(code+pc0+1))!=JBR_CP_CAST)goto done;
                    argc=refs=1;result_type=2;
                } else if(raw==0x2e||raw==0x32){argc=2;refs=1;result_type=raw==0x32?2:1;}
                else {
                    unsigned ix=raw==0x12?code[pc0+1]:jbr_u16(code+pc0+1);
                    if(cp(ctx,raw,ix)!=JBR_CP_LITERAL_INT)goto done;
                    result_type=1;v->plain_read=1;
                }
                if(!jbr_wide_pop(&t,argc,refs,&wide_uses))goto done;
                if(raw==0xb6&&v->closed_end){
                    if(!jbr_draw_shape(typ)||result_type||t.depth)goto done;
                    wide_uses=0;
                } else {
                    kind=JBR_WIDE_EFFECT;a=argc;b=t.depth;
                    imm=(int)(raw|(refs<<8));len=jbr_raw_size(raw);
                    if(result_type)d=jbr_push(&t,result_type==2);
                }
            }
            else if(raw==0xb2||raw==0xb3||raw==0xb8||raw==0xb6){
                int typ=cp(ctx,raw,jbr_u16(code+pc0+1));kind=JBR_EFFECT;imm=raw;len=3;
                if(raw==0xb2){
                    if(typ!=JBR_CP_INT&&typ!=JBR_CP_REF&&typ!=JBR_CP_PLAIN_INT)goto done;
                    d=jbr_push(&t,typ==JBR_CP_REF);
                    v->plain_read=typ==JBR_CP_PLAIN_INT;
                }
                else if(raw==0xb3){if(typ!=JBR_CP_INT)goto done;a=jbr_pop(&t,0);}
                else if(raw==0xb8){if(typ!=JBR_CP_INT2)goto done;b=jbr_pop(&t,0);a=jbr_pop(&t,0);d=jbr_push(&t,0);}
                else {if(typ!=JBR_CP_DRAW&&(draw_effects!=4||typ!=JBR_CP_DRAW_IMAGE))goto done;for(unsigned j=0;j<(typ==JBR_CP_DRAW_IMAGE?3u:8u);j++)if(jbr_pop(&t,0)<0)goto done;
                    b=jbr_pop(&t,1);a=jbr_pop(&t,1);if(a<0||b<0)goto done;
                    if(!draw_effects||draw_effects>=3){kind=JBR_NOP;a=b=JBR_NONE;imm=len=0;}}
            }
            else if(raw==0xa7)kind=JBR_NOP;
            else if(raw==0xb1){if(t.depth)goto done;kind=JBR_EFFECT;imm=raw;len=1;}
            else if(raw==0x74){kind=JBR_INEG;a=jbr_pop(&t,0);d=jbr_push(&t,0);}
            else if(raw==0xa5||raw==0xa6||raw==0xc6||raw==0xc7){
                if(raw<=0xa6)b=jbr_pop(&t,1);
                a=jbr_pop(&t,1);kind=raw==0xa5?JBR_IF_ACMPEQ:raw==0xa6?JBR_IF_ACMPNE:raw==0xc6?JBR_IFNULL:JBR_IFNONNULL;
            }
            else if(jbr_raw_branch(raw)){
                static const unsigned char kinds[]={JBR_IFEQ,JBR_IFNE,JBR_IFLT,JBR_IFGE,JBR_IFGT,JBR_IFLE,
                    JBR_IF_ICMPEQ,JBR_IF_ICMPNE,JBR_IF_ICMPLT,JBR_IF_ICMPGE,JBR_IF_ICMPGT,JBR_IF_ICMPLE};
                if(raw>=0x9f)b=jbr_pop(&t,0);
                a=jbr_pop(&t,0);kind=kinds[raw-0x99];
            }
            else {
                b=jbr_pop(&t,0);a=jbr_pop(&t,raw==0x34);
                {d=jbr_push(&t,0);switch(raw){
                    case 0x60:kind=JBR_IADD;break;case 0x64:kind=JBR_ISUB;break;
                    case 0x68:kind=JBR_IMUL;break;case 0x7e:kind=JBR_IAND;break;case 0x7a:kind=JBR_ISHR;break;case 0x78:kind=JBR_ISHL;break;
                    case 0x34:case 0x6c:case 0x70:kind=JBR_EFFECT;imm=raw;len=1;break;
                    default:goto done;}}
            }
            if(a<0||b<0||d<0)goto done;
            o->kind=kind;o->a=a;o->b=b;o->dst=d;o->imm=imm;o->length=len;
            v->uses=kind==JBR_WIDE_EFFECT?wide_uses:(a!=JBR_NONE?1u<<a:0)|(b!=JBR_NONE?1u<<b:0);v->defs=d!=JBR_NONE?1u<<d:0;
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
                // A possible continuation to the original interpreter is
                // an observer of all ordinary initialized integer locals.
                uint32_t roots=0;
                if(o->checkpoint)roots=draw_effects>=4?(n[i].initialized&14u)|((n[i].initialized&16u)?1u<<JBR_LOCAL4:0):14u;
                live=n[i].uses|(live&~n[i].defs)|roots;
                if(live!=n[i].live){n[i].live=live;changed=1;}
            }
            if(!changed)break;
        }
        for(unsigned i=0;i<count;i++) {
            JarBoxResidualOp *o=&n[i].op;
            uint32_t live=(o->next==JBR_END?0:n[o->next].live)|(o->alt==JBR_END?0:n[o->alt].live);
            // Only an already linked, initialized, nonvolatile primitive read
            // may cease to be a root. A live read still uses the original handler.
            if((!jbr_is_effect(o->kind)||n[i].plain_read)&&!o->checkpoint&&n[i].defs&&!(n[i].defs&live)){
                jbr_empty(n+i);n[i].plain_read=0;altered=1;
            }
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
        if(!n[i].reachable){if(jbr_is_effect(n[i].op.kind))goto done;continue;}
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
