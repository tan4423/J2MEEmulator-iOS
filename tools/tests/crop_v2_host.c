#include <assert.h>
#include <stdint.h>
#include <stdlib.h>
#include <stdio.h>
#include <stddef.h>
typedef struct {int x,y,w,h;} CGRect;
static CGRect CGRectMake(int x,int y,int w,int h){return (CGRect){x,y,w,h};}
typedef struct Fake {size_t stride,height; int refs; struct Fake *parent; CGRect rect;} *CGImageRef;
static unsigned live, creates, fail;
static CGImageRef make(size_t stride,size_t height){
    CGImageRef i=calloc(1,sizeof(*i)); assert(i); i->stride=stride;i->height=height;i->refs=1; ++live;return i;
}
static size_t CGImageGetBytesPerRow(CGImageRef i){return i->stride;}
static size_t CGImageGetHeight(CGImageRef i){return i->height;}
static CGImageRef CGImageRetain(CGImageRef i){assert(i && i->refs>0);++i->refs;return i;}
static void CGImageRelease(CGImageRef i){assert(i && i->refs>0);if (!--i->refs){if(i->parent)CGImageRelease(i->parent);free(i);--live;}}
static CGImageRef CGImageCreateWithImageInRect(CGImageRef i,CGRect r){
    ++creates;if(fail)return NULL;CGImageRef j=make((size_t)r.w*4,(size_t)r.h);
    j->parent=CGImageRetain(i);j->rect=r;return j;
}
#include "jarbox_crop_cache_v2.h"
static void validate(JarBoxCropCache *c){
    unsigned counts[JARBOX_CROP_SLOTS]={0};size_t sum=0;
    for(unsigned i=0;i<JARBOX_CROP_SLOTS;i++)if(c->entry[i].crop){
        JarBoxCropEntry *e=&c->entry[i];assert(e->source<JARBOX_CROP_SLOTS);
        assert(e->crop->parent==c->sources[e->source].image);
        ++counts[e->source];sum+=e->charge;
    }
    for(unsigned i=0;i<JARBOX_CROP_SLOTS;i++){
        JarBoxCropSource *s=&c->sources[i];assert(s->users==counts[i]);
        assert((s->image!=NULL)==(s->users!=0));sum+=s->charge;
    }
    assert(sum==c->bytes && sum+sizeof(*c)<=JARBOX_CROP_BUDGET);
}
int main(void){
    JarBoxCropCache a={0},b={0};int hit;unsigned hits=0;
    CGImageRef atlas=make(1024,256), other=make(1024,256);
    // Four distinct regions deliberately in one set, all fit one source charge.
    int xs[4],ys[4];unsigned count=0;
    for(int y=0;y<240 && count<4;y++)for(int x=0;x<240 && count<4;x++)
        if(jarbox_crop_set(atlas,x,y,8,8)==0){xs[count]=x;ys[count++]=y;}
    assert(count==4);
    for(unsigned i=0;i<40000;i++){
        unsigned k=i%4;CGImageRef q=jarbox_crop_get(&a,atlas,xs[k],ys[k],8,8,&hit);
        assert(q && q->parent==atlas && q->rect.x==xs[k] && q->rect.y==ys[k]);
        hits+=hit;CGImageRelease(q);validate(&a);
    }
    assert(hits==39996 && creates==4);
    assert(a.bytes==1024*256+4*(8*8*4+JARBOX_CROP_OVERHEAD));
    CGImageRef q=jarbox_crop_get(&b,atlas,xs[0],ys[0],8,8,&hit);assert(q && !hit);CGImageRelease(q);
    uint32_t seed=1;
    for(unsigned i=0;i<100000;i++){
        seed=seed*1664525u+1013904223u;int x=(seed>>8)%240;
        seed=seed*1664525u+1013904223u;int y=(seed>>8)%240;
        CGImageRef src=(seed&256)?atlas:other;
        size_t prev=a.bytes;fail=(i%97==0);
        q=jarbox_crop_get(&a,src,x,y,8,8,&hit);
        if(q){assert(q->parent==src && q->rect.x==x && q->rect.y==y);CGImageRelease(q);}
        else assert(fail && a.bytes==prev);
        validate(&a);validate(&b);
    }
    fail=0;CGImageRef large=make(SIZE_MAX,2);size_t prev=a.bytes;
    q=jarbox_crop_get(&a,large,0,0,2,2,&hit);assert(q && !hit && a.bytes==prev);CGImageRelease(q);CGImageRelease(large);
    CGImageRelease(atlas);CGImageRelease(other);
    jarbox_crop_clear(&a);jarbox_crop_clear(&a);validate(&a);assert(live>0);
    jarbox_crop_clear(&b);validate(&b);assert(!live);
    puts("PASS 40000 collision/atlas accesses, 100000 mixed accesses, budget and owner invariants");
}
