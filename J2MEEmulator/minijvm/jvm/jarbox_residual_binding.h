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
    JClass *wrapper_class,*canvas_class,*graphics_class;
    uint32_t w_graphics,c_graphics,c_context,c_buffer,c_current;
    uint32_t g_context,g_owns,g_pixels,g_headless;
    unsigned ready;
} JarBoxResidualGuard;
typedef struct {
    uint64_t owner, serial;
    int64_t context;
    uintptr_t wrapper, canvas, graphics;
    JarBoxResidualGuard guard;
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
    Instance *v=NULL;
    if(!p||!expected)return 0;
    memcpy(&v,p,sizeof(v));
    return v==expected;
}
static inline int jbr_bzero(JClass *cl,Instance *obj,const char *name) {
    const unsigned char *p=jbr_bfield(cl,obj,name,"Z",1,0,0);
    return p&&!*p;
}
static inline int jbr_bcontext(JClass *cl,Instance *obj,int64_t *v) {
    const void *p=jbr_bfield(cl,obj,"nativeContext","J",sizeof(*v),0,0);
    if(!p)return 0;
    memcpy(v,p,sizeof(*v));
    return *v!=0;
}

// The scope is frame-local. Actual Canvas and Graphics remain rooted by the
// original paint frames; no object/field pointer is cached in a global plan.
// Cache immutable offsets once, but reread every mutable field at each guard.
static inline int jbr_guard_offset(JClass *cl,Instance *o,const char *name,const char *desc,
                                  size_t width,int ref,uint32_t *out) {
    const unsigned char *p=jbr_bfield(cl,o,name,desc,width,ref,!o);
    const unsigned char *base=o?(const unsigned char *)o->obj_fields:(const unsigned char *)cl->field_static;
    if(!p||!base||(uintptr_t)p<(uintptr_t)base||(uintptr_t)p-(uintptr_t)base>UINT32_MAX)return 0;
    *out=(uint32_t)((uintptr_t)p-(uintptr_t)base);return 1;
}
static inline int jbr_guard_ref(const unsigned char *base,uint32_t off,Instance *want){
    Instance *v=NULL;memcpy(&v,base+off,sizeof(v));return v==want;
}
static inline int jbr_guard_context(const unsigned char *base,uint32_t off,int64_t want){
    int64_t v;memcpy(&v,base+off,sizeof(v));return v==want;
}
static inline int jbr_scope_fields_valid(const JarBoxResidualScope *s,Instance *wrapper){
    if(!s||!s->guard.ready||!s->context||!wrapper||(uintptr_t)wrapper!=s->wrapper)return 0;
    const JarBoxResidualGuard *q=&s->guard;
    Instance *c=(Instance *)s->canvas,*g=(Instance *)s->graphics;
    if(!jbr_bobject(wrapper,q->wrapper_class)||!jbr_bobject(c,q->canvas_class)||
       !jbr_bobject(g,q->graphics_class)||!q->canvas_class->field_static)return 0;
    const unsigned char *wb=(const unsigned char *)wrapper->obj_fields;
    const unsigned char *cb=(const unsigned char *)c->obj_fields;
    const unsigned char *gb=(const unsigned char *)g->obj_fields;
    return jbr_guard_ref(wb,q->w_graphics,g)&&jbr_guard_ref(cb,q->c_graphics,g)&&
        jbr_guard_ref((const unsigned char *)q->canvas_class->field_static,q->c_current,c)&&
        jbr_guard_context(cb,q->c_context,s->context)&&jbr_guard_context(gb,q->g_context,s->context)&&
        !cb[q->c_buffer]&&!gb[q->g_owns]&&!gb[q->g_pixels]&&!gb[q->g_headless];
}
static inline int jbr_scope_prepare_fields(JarBoxResidualScope *s){
    if(!s||!s->wrapper||!s->canvas||!s->graphics)return 0;
    JarBoxResidualGuard *q=&s->guard;memset(q,0,sizeof(*q));
    Instance *w=(Instance *)s->wrapper,*c=(Instance *)s->canvas,*g=(Instance *)s->graphics;
    q->wrapper_class=w->mb.clazz;q->canvas_class=c->mb.clazz;q->graphics_class=g->mb.clazz;
    if(!jbr_bobject(w,q->wrapper_class)||!jbr_bobject(c,q->canvas_class)||
       !jbr_bobject(g,q->graphics_class)||!q->canvas_class->superclass)return 0;
    JClass *api=q->canvas_class->superclass;
    const char *gd="Ljavax/microedition/lcdui/Graphics;";
    if(!jbr_guard_offset(q->wrapper_class,w,"a",gd,sizeof(Instance *),1,&q->w_graphics)||
       !jbr_guard_offset(api,c,"graphics",gd,sizeof(Instance *),1,&q->c_graphics)||
       !jbr_guard_offset(api,c,"nativeContext","J",8,0,&q->c_context)||
       !jbr_guard_offset(api,c,"treoUsesExplicitBuffer","Z",1,0,&q->c_buffer)||
       !jbr_guard_offset(q->canvas_class,NULL,"g","LClass_hef;",sizeof(Instance *),1,&q->c_current)||
       !jbr_guard_offset(q->graphics_class,g,"nativeContext","J",8,0,&q->g_context)||
       !jbr_guard_offset(q->graphics_class,g,"ownsContext","Z",1,0,&q->g_owns)||
       !jbr_guard_offset(q->graphics_class,g,"treoPixelDependent","Z",1,0,&q->g_pixels)||
       !jbr_guard_offset(q->graphics_class,g,"headless","Z",1,0,&q->g_headless))return 0;
    q->ready=1;
    if(!jbr_scope_fields_valid(s,w)){q->ready=0;return 0;}
    return 1;
}

// The exact corpus has one direct caller of k1 (Class_hmi.m PC58),
// one direct paint delegate call (Class_hef.paint PC5), and one writer
// of an existing wrapper's Graphics (Class_hxb.a PC8). c3 is created
// per delegate in its constructor. Reject offscreen/mismatched ancestry.
static inline int jbr_binding_route(Runtime *r,Instance *wrapper,JarBoxResidualBinding *out,
                                 unsigned map_pc,unsigned delegate_pc,unsigned paint_pc,unsigned route_pc) {
    static const char *gd="(Ljavax/microedition/lcdui/Graphics;)V";
    static const char *wd="(LClass_hvi;)V";
    if(out)memset(out,0,sizeof(*out));
    if(!out||!r||!r->jvm||!r->thrd_info||!r->stack)return 0;
    const int overlay=jbr_bmethod(r->method,"Class_hii","i3",wd);
    const int minimap=jbr_bmethod(r->method,"Class_hii","r2",wd);
    const int background=jbr_bmethod(r->method,"Class_hxb","j1",wd);
    if((!overlay&&!minimap&&!background&&!jbr_bmethod(r->method,"Class_hii","k1",wd))||!r->method->is_static)return 0;
    JClass *map=r->method->_this_class;
    if(!wrapper||!jbr_bname(wrapper->mb.clazz,"Class_hvi")||
       !jbr_bobject(wrapper,wrapper->mb.clazz))return 0;
    JClass *wc=wrapper->mb.clazz;
    Runtime *p=r->parent;
    if(overlay||background){
        // Real Nick map/overlay path (background is a0 PC58): Class_hmi.i(Class_hac,Class_hvi)
        // PC54 -> Class_hac.a0(Class_hvi) PC2044 -> Class_hii.i3.
        if(!jbr_bframe(p,r,2)||!jbr_bmethod(p->method,"Class_hac","a0",wd)||
           p->method->is_static||!jbr_bpc(p,map_pc)||p->localvar[1].rvalue!=wrapper||
           !jbr_bobject(p->localvar[0].rvalue,p->method->_this_class)||
           !(p->method->_this_class->cff.access_flags&16)||
           p->method->_this_class->jloader!=map->jloader)return 0;
        Runtime *route=p->parent;
        if(!jbr_bframe(route,r,2)||
           !jbr_bmethod(route->method,"Class_hmi","i","(LClass_hac;LClass_hvi;)V")||
           !route->method->is_static||!jbr_bpc(route,route_pc)||
           route->localvar[0].rvalue!=p->localvar[0].rvalue||
           route->localvar[1].rvalue!=wrapper||
           route->method->_this_class->jloader!=map->jloader)return 0;
        p=route;
    } else if(!jbr_bframe(p,r,1)||!jbr_bmethod(p->method,"Class_hmi",minimap?"k":"m",wd)||
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
static inline int jbr_binding_at(Runtime *r,Instance *wrapper,JarBoxResidualBinding *out,
                                 unsigned map_pc,unsigned delegate_pc,unsigned paint_pc) {
    return jbr_binding_route(r,wrapper,out,map_pc,delegate_pc,paint_pc,0);
}
static inline int jbr_nick_binding(Runtime *r,Instance *wrapper,JarBoxResidualBinding *out) {
    const int overlay=r&&jbr_bmethod(r->method,"Class_hii","i3","(LClass_hvi;)V");
    return jbr_binding_route(r,wrapper,out,overlay?2044:58,30,5,54);
}
#endif
