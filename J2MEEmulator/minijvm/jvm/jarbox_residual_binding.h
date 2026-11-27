#ifndef JARBOX_RESIDUAL_BINDING_H
#define JARBOX_RESIDUAL_BINDING_H
#include <stdint.h>
#include <string.h>

// Include after jvm.h. Read-only preflight for the exact audited Nick t5
// binding. Not an archive/API identity check or a runtime admission by itself.
// No resolution, allocation, Java execution, cached object pointers or locks.
typedef struct {
    Instance *wrapper, *canvas, *graphics;
    int64_t context;
} JarBoxResidualBinding;

typedef struct {
    uint64_t owner, serial;
    int64_t context;
    uintptr_t wrapper, canvas, graphics;
} JarBoxResidualScope;

static inline int jbr_scope_same(const JarBoxResidualScope *a,const JarBoxResidualScope *b) {
    return a&&b&&a->owner&&a->serial&&a->context&&a->wrapper&&a->canvas&&a->graphics&&
           a->owner==b->owner&&a->serial==b->serial&&a->context==b->context&&
           a->wrapper==b->wrapper&&a->canvas==b->canvas&&a->graphics==b->graphics;
}

static inline int jbr_bname(JClass *c,const char *name) {
    return c&&c->name&&utf8_equals_c(c->name,name);
}
static inline int jbr_bobject(Instance *o,JClass *c) {
    return o&&c&&o->mb.type==MEM_TYPE_INS&&o->mb.clazz==c&&o->obj_fields;
}
static inline int jbr_bmethod(MethodInfo *m,const char *owner,const char *name,const char *desc) {
    return m&&!m->is_native&&m->converted_code&&jbr_bname(m->_this_class,owner)&&
        m->name&&m->descriptor&&utf8_equals_c(m->name,name)&&utf8_equals_c(m->descriptor,desc);
}
static inline int jbr_bpc(Runtime *r,unsigned pc) {
    CodeAttribute *ca=r&&r->method?r->method->converted_code:NULL;
    return ca&&ca->code&&ca->code_length>0&&pc<(unsigned)ca->code_length&&
        r->pc==ca->code+pc;
}
static inline int jbr_bframe(Runtime *r,Runtime *root,unsigned n) {
    if(!r||!root||r->jvm!=root->jvm||r->thrd_info!=root->thrd_info||r->stack!=root->stack||
       !r->localvar||r->localvar_slots<(int)n||!root->stack)return 0;
    const uintptr_t lo=(uintptr_t)root->stack->store,hi=(uintptr_t)root->stack->sp;
    const uintptr_t at=(uintptr_t)r->localvar;
    return lo&&hi>=lo&&at>=lo&&at<=hi&&n*sizeof(StackEntry)<=hi-at&&
        (at-lo)%sizeof(StackEntry)==0;
}
static inline const void *jbr_bfield(JClass *decl,Instance *obj,const char *name,const char *desc,
                                    size_t bytes,int isref,int isstatic) {
    if(!decl||decl->status<CLASS_STATUS_CLINITED||decl->fieldPool.field_used<0||
       decl->fieldPool.field_used>4096||!decl->fieldPool.field)return NULL;
    const void *result=NULL;
    for(int i=0;i<decl->fieldPool.field_used;i++) {
        FieldInfo *f=decl->fieldPool.field+i;
        if(!f->name||!f->descriptor||!utf8_equals_c(f->name,name)||!utf8_equals_c(f->descriptor,desc))continue;
        if(result||f->_this_class!=decl||f->isvolatile||!!f->isrefer!=isref||
           !!(f->access_flags&8)!=isstatic)return NULL;
        if(isstatic) {
            if(!decl->field_static||decl->field_static_len<0||
               (size_t)f->offset+bytes>(size_t)decl->field_static_len)return NULL;
            result=decl->field_static+f->offset;
        } else {
            if(!obj||obj->mb.type!=MEM_TYPE_INS||!obj->mb.clazz||!obj->obj_fields||
               (obj->mb.clazz!=decl&&obj->mb.clazz->superclass!=decl)||
               decl->field_instance_len<0||obj->mb.clazz->field_instance_len<0||
               (size_t)f->offset_instance+bytes>(size_t)decl->field_instance_len||
               (size_t)f->offset_instance+bytes>(size_t)obj->mb.clazz->field_instance_len)return NULL;
            result=obj->obj_fields+f->offset_instance;
        }
    }
    return result;
}
static inline int jbr_bref(JClass *cl,Instance *obj,const char *name,const char *desc,Instance *expected,int isstatic) {
    const void *p=jbr_bfield(cl,obj,name,desc,sizeof(Instance *),1,isstatic);
    Instance *v=NULL;if(!p||!expected)return 0;memcpy(&v,p,sizeof(v));return v==expected;
}
static inline int jbr_bzero(JClass *cl,Instance *obj,const char *name) {
    const unsigned char *p=jbr_bfield(cl,obj,name,"Z",1,0,0);
    return p&&!*p;
}
static inline int jbr_bcontext(JClass *cl,Instance *obj,int64_t *v) {
    const void *p=jbr_bfield(cl,obj,"nativeContext","J",sizeof(*v),0,0);
    if(!p)return 0;memcpy(v,p,sizeof(*v));return *v!=0;
}

// The exact corpus has one direct caller of k1 (Class_hmi.m PC58),
// one direct paint delegate call (Class_hef.paint PC5), and one writer
// of an existing wrapper's Graphics (Class_hxb.a PC8). c3 is created
// per delegate in its constructor. Reject offscreen/mismatched ancestry.
static inline int jbr_binding_at(Runtime *r,Instance *wrapper,JarBoxResidualBinding *out,
                                 unsigned map_pc,unsigned delegate_pc,unsigned paint_pc) {
    static const char *gd="(Ljavax/microedition/lcdui/Graphics;)V";
    static const char *wd="(LClass_hvi;)V";
    if(out)memset(out,0,sizeof(*out));
    if(!out||!r||!r->jvm||!r->thrd_info||!r->stack||
       !jbr_bmethod(r->method,"Class_hii","k1",wd)||!r->method->is_static)return 0;
    JClass *map=r->method->_this_class;
    if(!wrapper||!jbr_bname(wrapper->mb.clazz,"Class_hvi")||
       !jbr_bobject(wrapper,wrapper->mb.clazz))return 0;
    JClass *wc=wrapper->mb.clazz;
    Runtime *p=r->parent;
    if(!jbr_bframe(p,r,1)||!jbr_bmethod(p->method,"Class_hmi","m",wd)||
       !p->method->is_static||!jbr_bpc(p,map_pc)||p->localvar[0].rvalue!=wrapper||
       p->method->_this_class->jloader!=map->jloader)return 0;
    Runtime *delegate=NULL;
    for(unsigned n=0;p&&n<64;n++,p=p->parent) {
        if(!jbr_bframe(p,r,0))return 0;
        if(jbr_bmethod(p->method,"Class_hxb","a",gd)){delegate=p;break;}
    }
    if(!jbr_bframe(delegate,r,2)||delegate->method->is_static||!jbr_bpc(delegate,delegate_pc))return 0;
    Runtime *paint=delegate->parent;
    if(!jbr_bframe(paint,r,2)||!jbr_bmethod(paint->method,"Class_hef","paint",gd)||
       paint->method->is_static||!jbr_bpc(paint,paint_pc))return 0;
    Runtime *canvas_frame=paint->parent;
    if(!jbr_bframe(canvas_frame,r,1)||
       !jbr_bmethod(canvas_frame->method,"javax/microedition/lcdui/Canvas","doPaint","()V")||
       canvas_frame->method->is_static)return 0;
    Instance *d=delegate->localvar[0].rvalue,*g=delegate->localvar[1].rvalue;
    Instance *c=paint->localvar[0].rvalue;
    JClass *dc=delegate->method->_this_class,*cc=paint->method->_this_class;
    JClass *api=canvas_frame->method->_this_class;
    if(!jbr_bobject(d,dc)||!jbr_bobject(c,cc)||!g||
       !jbr_bobject(g,g->mb.clazz)||!jbr_bname(g->mb.clazz,"javax/microedition/lcdui/Graphics")||
       cc->superclass!=api||paint->localvar[1].rvalue!=g||canvas_frame->localvar[0].rvalue!=c||
       !(wc->cff.access_flags&16)||!(dc->cff.access_flags&16)||!(cc->cff.access_flags&16)||
       wc->jloader!=map->jloader||dc->jloader!=map->jloader||cc->jloader!=map->jloader||
       g->mb.clazz->jloader!=api->jloader)return 0;
    if(!jbr_bref(dc,d,"c3","LClass_hvi;",wrapper,0)||
       !jbr_bref(cc,c,"b","LClass_bs;",d,0)||
       !jbr_bref(cc,NULL,"g","LClass_hef;",c,1)||
       !jbr_bref(wc,wrapper,"a","Ljavax/microedition/lcdui/Graphics;",g,0)||
       !jbr_bref(api,c,"graphics","Ljavax/microedition/lcdui/Graphics;",g,0)||
       !jbr_bzero(api,c,"treoUsesExplicitBuffer")||
       !jbr_bzero(g->mb.clazz,g,"ownsContext")||
       !jbr_bzero(g->mb.clazz,g,"treoPixelDependent")||
       !jbr_bzero(g->mb.clazz,g,"headless"))return 0;
    int64_t cctx=0,gctx=0;
    if(!jbr_bcontext(api,c,&cctx)||!jbr_bcontext(g->mb.clazz,g,&gctx)||cctx!=gctx)return 0;
    out->wrapper=wrapper;out->canvas=c;out->graphics=g;out->context=cctx;return 1;
}
static inline int jbr_nick_binding(Runtime *r,Instance *wrapper,JarBoxResidualBinding *out) {
    return jbr_binding_at(r,wrapper,out,58,30,5);
}
#endif
