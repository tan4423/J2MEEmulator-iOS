#ifndef JARBOX_RENDER_ISLAND_H
#define JARBOX_RENDER_ISLAND_H
#include "jarbox_block_ir.h"

/* General closed render-expression certificates, independent of method
 * signature, original stack depth, obfuscation and residual slot limits.
 * CP classifier supplies symbolic types, not authority to omit effects.
 * The runtime MUST prove the exact sink and every static read is ready. */
enum { JRI_MAX_ISLANDS=256,JRI_MAX_STEPS=64,JRI_MAX_READS=16,JRI_MAX_ARGS=12 };
enum { JRI_REF_NONE,JRI_REF_LOCAL,JRI_REF_STATIC,JRI_REF_NULL };
typedef struct {
    uint16_t pc,call,end,receiver,cp,steps,peak,nreads;
    uint16_t argc,ref_kind,ref_index;
    uint16_t reads[JRI_MAX_READS];
} JriIsland;
typedef struct {unsigned count;JriIsland island[];} JriPlan;
/* 1=integer, 2=reference for getstatic; invoke shape = argc including
 * receiver, low 4 bits, reference mask in upper bits. Zero means unknown. */
typedef unsigned (*JriCP)(void *,unsigned,unsigned);
static inline unsigned jri_shape(unsigned argc,unsigned refs){return argc|(refs<<4);}
static inline int jri_load(const uint8_t *p,unsigned locals,int be,unsigned *local,unsigned *ref){
    unsigned op=p[0],l=0;
    if(op==0xc4){op=p[1];l=jbi_u16(p+2,be);}
    else if(op==0x15||op==0x19)l=p[1];
    else if(op>=0x1a&&op<=0x1d){l=op-0x1a;op=0x15;}
    else if(op>=0x2a&&op<=0x2d){l=op-0x2a;op=0x19;}
    else return 0;
    if((op!=0x15&&op!=0x19)||l>=locals)return 0;
    *local=l;*ref=op==0x19;return 1;
}
static inline JriPlan *jri_build(const uint8_t *c,unsigned size,unsigned locals,unsigned maxstack,
        const JbiHandler *handlers,unsigned nh,int be,JriCP cp,void *ctx){
    if(!c||!cp||size<5||size>JBI_MAX_CODE||locals>32767||maxstack>32767||
       nh>JBI_MAX_HANDLERS||(nh&&!handlers))return NULL;
    uint8_t width[JBI_MAX_CODE]={0},targets[JBI_MAX_CODE]={0};
    for(unsigned pc=0;pc<size;){
        unsigned w=jbi_width(c,size,pc,be,targets);
        if(!w)return NULL;
        /* Switches may be >255 bytes; no candidate can start there. */
        width[pc]=w>255?255:(uint8_t)w;pc+=w;
    }
    for(unsigned i=0;i<nh;++i){
        JbiHandler h=handlers[i];
        if(h.start>=h.end||h.end>size||h.handler>=size)return NULL;
        targets[h.start]=targets[h.handler]=1;if(h.end<size)targets[h.end]=1;
    }
    for(unsigned pc=0;pc<size;++pc)if(targets[pc]&&!width[pc])return NULL;
    JriIsland found[JRI_MAX_ISLANDS];unsigned count=0;
    for(unsigned start=0;start<size;++start){
        unsigned local,ref;
        if(!width[start]||!jri_load(c+start,locals,be,&local,&ref)||!ref)continue;
        JriIsland x={.pc=(uint16_t)start,.receiver=(uint16_t)local,.peak=1};
        unsigned depth=1,refs=1,p=start+width[start],steps=1;
        for(;p<size&&steps<JRI_MAX_STEPS;++steps){
            unsigned w=width[p],op=c[p],l=0,r=0;
            if(!w||targets[p])break;
            if(op==0xb6){
                unsigned ix=jbi_u16(c+p+1,be),shape=cp(ctx,op,ix);
                if(!shape||(shape&15)!=depth||(shape>>4)!=refs||depth>JRI_MAX_ARGS||p+w>=size)break;
                x.argc=(uint16_t)depth;
                x.call=(uint16_t)p;x.end=(uint16_t)(p+w);x.cp=(uint16_t)ix;x.steps=(uint16_t)(steps+1);
                if(count==JRI_MAX_ISLANDS)return NULL;
                found[count++]=x;start=x.end-1;break;
            }
            if(jri_load(c+p,locals,be,&l,&r)){
                if(depth==JRI_MAX_ARGS)break;
                if(r){if(depth!=1)break;refs|=1u<<depth;x.ref_kind=JRI_REF_LOCAL;x.ref_index=(uint16_t)l;}
                ++depth;
            }else if(op==0xb2){
                unsigned ix=jbi_u16(c+p+1,be),t=cp(ctx,op,ix);
                if((t!=1&&t!=2)||x.nreads==JRI_MAX_READS||depth==JRI_MAX_ARGS)break;
                x.reads[x.nreads++]=(uint16_t)ix;
                if(t==2){if(depth!=1)break;refs|=1u<<depth;x.ref_kind=JRI_REF_STATIC;x.ref_index=(uint16_t)ix;}
                ++depth;
            }else if(op==0x01||(op>=2&&op<=8)||op==0x10||op==0x11){
                if(depth==JRI_MAX_ARGS)break;
                if(op==1){if(depth!=1)break;refs|=1u<<depth;x.ref_kind=JRI_REF_NULL;}
                ++depth;
            }else if(op==0x60||op==0x64||op==0x68||op==0x78||op==0x7a||op==0x7c||op==0x7e||op==0x80||op==0x82){
                if(depth<3||(refs&(3u<<(depth-2))))break;
                --depth;
            }else if(op==0x74||op==0x91||op==0x92||op==0x93){
                if(depth<2||(refs&(1u<<(depth-1))))break;
            }else break; /* any other call, field, array, allocation, fault or write */
            if(depth>maxstack)break;
            if(depth>x.peak)x.peak=(uint16_t)depth;
            p+=w;
        }
    }
    if(!count)return NULL;
    JriPlan *plan=malloc(sizeof(*plan)+count*sizeof(*found));
    if(plan){plan->count=count;memcpy(plan->island,found,count*sizeof(*found));}
    return plan;
}
static inline const JriIsland *jri_find(const JriPlan *p,unsigned pc){
    if(!p)return NULL;
    unsigned l=0,r=p->count;
    while(l<r){unsigned m=l+(r-l)/2;if(p->island[m].pc<pc)l=m+1;else r=m;}
    return l<p->count&&p->island[l].pc==pc?p->island+l:NULL;
}
/* The audited Nick wrapper has max_locals=argc; its only extra reference
 * writes before the bundled Graphics early-return are Graphics at argc
 * and (for image sinks) the source at argc+1. Integer lanes are dead.
 * Caller must check exact wrapper, sink, scope, and 2*argc physical room. */
static inline void jri_replay_wrapper_refs(StackEntry *sp,const JriIsland *s,
        void *wrapper,void *graphics,void *image){
    sp[0].rvalue=wrapper;sp[s->argc].rvalue=graphics;
    if(s->ref_kind!=JRI_REF_NONE){sp[1].rvalue=image;sp[s->argc+1].rvalue=image;}
}
#endif
