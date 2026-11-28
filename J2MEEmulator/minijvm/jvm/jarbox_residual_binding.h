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
#if defined(JARBOX_DESKTOP_LAB) && JARBOX_DESKTOP_LAB
/* Direct-mapped owner-local metadata. Collisions only cause a scan.
 * No cached mutable object, value, or negative answer. */
static inline unsigned jbr_proof_slot(const char *name,const char *desc){
    unsigned h=(unsigned char)name[0]*31u+(unsigned char)desc[0];
    if(name[0])h=h*31u+(unsigned char)name[1];
    if(desc[0])h=h*31u+(unsigned char)desc[1];
    return h&15u;
}
static inline FieldInfo *jbr_proof_field(JClass *cl,const char *name,const char *desc){
    unsigned slot=jbr_proof_slot(name,desc);
    FieldInfo *f=__atomic_load_n(&cl->desktop_proof_fields[slot],__ATOMIC_ACQUIRE);
    if(f&&f->_this_class==cl&&f->name&&f->descriptor&&utf8_equals_c(f->name,name)&&utf8_equals_c(f->descriptor,desc))return f;
    f=NULL;
    for(int i=0;i<cl->fieldPool.field_used;i++){
        FieldInfo *v=cl->fieldPool.field+i;
        if(!v->name||!v->descriptor||!utf8_equals_c(v->name,name)||!utf8_equals_c(v->descriptor,desc))continue;
        if(f||v->_this_class!=cl)return NULL;
        f=v;
    }
    // Only fully initialized classes publish metadata. Cold classes retry.
    if(f&&cl->status==CLASS_STATUS_CLINITED)__atomic_store_n(&cl->desktop_proof_fields[slot],f,__ATOMIC_RELEASE);
    return f;
}
static inline const void *jbr_bfield(JClass *decl,Instance *obj,const char *name,const char *desc,
                                    size_t bytes,int isref,int isstatic) {
    if(!decl||decl->status<CLASS_STATUS_CLINITED||decl->fieldPool.field_used<0||
       decl->fieldPool.field_used>4096||!decl->fieldPool.field)return NULL;
    FieldInfo *f=jbr_proof_field(decl,name,desc);
    if(!f||f->_this_class!=decl||f->isvolatile||!!f->isrefer!=isref||
       !!(f->access_flags&8)!=isstatic)return NULL;
    if(isstatic) {
        if(!decl->field_static||decl->field_static_len<0||
           (size_t)f->offset+bytes>(size_t)decl->field_static_len)return NULL;
        return decl->field_static+f->offset;
    }
    if(!obj||obj->mb.type!=MEM_TYPE_INS||!obj->mb.clazz||!obj->obj_fields||
       (obj->mb.clazz!=decl&&obj->mb.clazz->superclass!=decl)||
       decl->field_instance_len<0||obj->mb.clazz->field_instance_len<0||
       (size_t)f->offset_instance+bytes>(size_t)decl->field_instance_len||
       (size_t)f->offset_instance+bytes>(size_t)obj->mb.clazz->field_instance_len)return NULL;
    return obj->obj_fields+f->offset_instance;
}
#else
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
#endif
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
    const char *current_name=NULL,*current_desc=NULL;
    if(jbr_bname(q->canvas_class,"Class_hef")){
        current_name="g";current_desc="LClass_hef;";
    }else if(jbr_bname(q->canvas_class,"main/b")){
        current_name="a";current_desc="Lmain/b;";
    }else return 0;
    if(!jbr_guard_offset(q->wrapper_class,w,"a",gd,sizeof(Instance *),1,&q->w_graphics)||
       !jbr_guard_offset(api,c,"graphics",gd,sizeof(Instance *),1,&q->c_graphics)||
       !jbr_guard_offset(api,c,"nativeContext","J",8,0,&q->c_context)||
       !jbr_guard_offset(api,c,"treoUsesExplicitBuffer","Z",1,0,&q->c_buffer)||
       !jbr_guard_offset(q->canvas_class,NULL,current_name,current_desc,sizeof(Instance *),1,&q->c_current)||
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
/* Shared proof of the actual Canvas/delegate/wrapper at a specific
 * already audited delegate callsite. Never use this without the enclosing
 * archive and native TLS/owner eligibility checks. */
static inline int jbr_binding_paint_tail(Runtime *r,Runtime *p,Instance *wrapper,JClass *map,
        JarBoxResidualBinding *out,unsigned delegate_pc,unsigned paint_pc){
    static const char *gd="(Ljavax/microedition/lcdui/Graphics;)V";
    JClass *wc=wrapper->mb.clazz;
    Runtime *delegate=NULL;
    for(unsigned n=0;p&&n<64;n++,p=p->parent) {
        if(!jbr_bframe(p,r,0))return 0;
        if(jbr_bmethod(p->method,"Class_hxb","a",gd)){delegate=p;break;}
    }
    if(!jbr_bframe(delegate,r,2)||delegate->method->is_static)return 0;
    if(delegate_pc==UINT32_MAX){
        // The exact Nick screen dispatcher has five audited draw routes.
        // This broader certificate is for the whole glyph loop only.
        if(!jbr_bpc(delegate,30)&&!jbr_bpc(delegate,90)&&!jbr_bpc(delegate,106)&&
           !jbr_bpc(delegate,128)&&!jbr_bpc(delegate,135))return 0;
    }else if(!jbr_bpc(delegate,delegate_pc))return 0;
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
static inline int jbr_binding_route(Runtime *r,Instance *wrapper,JarBoxResidualBinding *out,
                                 unsigned map_pc,unsigned delegate_pc,unsigned paint_pc,unsigned route_pc) {
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
    return jbr_binding_paint_tail(r,p,wrapper,map,out,delegate_pc,paint_pc);
}
/* General island entry: only a descendant of the existing audited
 * screen delegate call (not menu/offscreen or a wrapper by name alone).
 * Old residual route checks above are unchanged. */
static inline int jbr_nick_paint_binding_at(Runtime *r,Instance *wrapper,
        JarBoxResidualBinding *out,unsigned delegate_pc,unsigned paint_pc){
    if(out)memset(out,0,sizeof(*out));
    if(!out||!r||!r->jvm||!r->thrd_info||!r->stack||!r->method||
       !r->method->_this_class||!wrapper||
       !jbr_bname(wrapper->mb.clazz,"Class_hvi")||
       !jbr_bobject(wrapper,wrapper->mb.clazz)||
       wrapper->mb.clazz->jloader!=r->method->_this_class->jloader)return 0;
    return jbr_binding_paint_tail(r,r->parent,wrapper,r->method->_this_class,out,delegate_pc,paint_pc);
}
static inline int jbr_nick_glyph_binding(Runtime *r,Instance *wrapper,JarBoxResidualBinding *out){
    return jbr_nick_paint_binding_at(r,wrapper,out,UINT32_MAX,5);
}

static inline int jbr_ninja_glyph_binding(Runtime *r,Instance *wrapper,JarBoxResidualBinding *out){
    static const char *gd="(Ljavax/microedition/lcdui/Graphics;)V";
    static const char *graphics_desc="Ljavax/microedition/lcdui/Graphics;";
    static const unsigned char delegate_digest[32]={0xf3,0xad,0xdd,0xb0,0x9d,0x11,0x60,0x90,0x37,0xf3,0xb3,0xb9,0x41,0xe0,0x62,0x33,0x61,0x60,0x81,0x76,0xba,0x3d,0xfe,0x9a,0x69,0x1c,0x31,0x2b,0xb0,0xf7,0xf5,0x64};
    static const unsigned char paint_render_digest[32]={0x59,0x47,0x9f,0xe4,0xa5,0x88,0xc1,0x57,0xa5,0x65,0x84,0xf8,0x18,0x5c,0xdd,0xc6,0x84,0x94,0x7e,0xdb,0x77,0x7d,0xd1,0x03,0xa2,0x41,0xc6,0xa9,0xcf,0x05,0xa7,0x6b};
    static const unsigned char paint_digest[32]={0xda,0x85,0x84,0x50,0xe1,0x4a,0xf4,0xac,0xd7,0xa0,0x72,0x63,0x69,0x05,0xf7,0x59,0x0c,0xd9,0xc5,0xce,0x4d,0x02,0xb0,0x74,0x0b,0x1b,0x53,0x4b,0x89,0x6b,0xf4,0xcf};
    if(out)memset(out,0,sizeof(*out));
    if(!out||!r||!r->jvm||!r->thrd_info||!r->stack||!wrapper||
       !jbr_bname(wrapper->mb.clazz,"t")||!jbr_bobject(wrapper,wrapper->mb.clazz))return 0;
    Runtime *delegate=NULL;
    for(Runtime *p=r->parent;p;p=p->parent){
        if(!jbr_bframe(p,r,0))return 0;
        if(jbr_bmethod(p->method,"main/a","a",gd)){delegate=p;break;}
    }
    if(!jbr_bframe(delegate,r,2)||delegate->method->is_static||
       delegate->method->converted_code->max_stack!=6||
       delegate->method->converted_code->max_locals!=2||
       delegate->method->converted_code->exception_table_length!=1||
       !jbr_live_code(delegate->method->converted_code,237,delegate_digest))return 0;
    Runtime *paint_render=delegate->parent;
    if(!jbr_bframe(paint_render,r,2)||
       !jbr_bmethod(paint_render->method,"main/b","paint$render",gd)||
       !jbr_bpc(paint_render,5)||paint_render->method->is_static||
       paint_render->method->converted_code->max_stack!=2||
       paint_render->method->converted_code->max_locals!=2||
       paint_render->method->converted_code->exception_table_length||
       !jbr_live_code(paint_render->method->converted_code,9,paint_render_digest))return 0;
    Runtime *paint=paint_render->parent;
    if(!jbr_bframe(paint,r,2)||!jbr_bmethod(paint->method,"main/b","paint",gd)||
       !jbr_bpc(paint,6)||paint->method->is_static||
       paint->method->converted_code->max_stack!=3||
       paint->method->converted_code->max_locals!=3||
       paint->method->converted_code->exception_table_length!=1||
       !jbr_live_code(paint->method->converted_code,37,paint_digest))return 0;
    Runtime *canvas_frame=paint->parent;
    if(!jbr_bframe(canvas_frame,r,1)||
       !jbr_bmethod(canvas_frame->method,"javax/microedition/lcdui/Canvas","doPaint","()V")||
       canvas_frame->method->is_static)return 0;
    Instance *d=delegate->localvar[0].rvalue,*g=delegate->localvar[1].rvalue;
    Instance *c=paint->localvar[0].rvalue;
    JClass *dc=delegate->method->_this_class,*cc=paint->method->_this_class;
    JClass *api=canvas_frame->method->_this_class,*wc=wrapper->mb.clazz;
    JClass *font_class=r->method->_this_class;
    if(!jbr_bname(dc,"main/a")||!dc->superclass||!jbr_bname(dc->superclass,"main/c")||
       !jbr_bname(cc,"main/b")||!cc->superclass||cc->superclass!=api||
       !jbr_bname(api,"javax/microedition/lcdui/Canvas")||
       !jbr_bname(font_class,"dd")||!jbr_bobject(d,dc)||!jbr_bobject(c,cc)||
       !g||!jbr_bobject(g,g->mb.clazz)||!jbr_bname(g->mb.clazz,"javax/microedition/lcdui/Graphics")||
       paint_render->localvar[0].rvalue!=c||paint_render->localvar[1].rvalue!=g||
       paint->localvar[1].rvalue!=g||canvas_frame->localvar[0].rvalue!=c||
       !(wc->cff.access_flags&ACC_FINAL)||!(dc->cff.access_flags&ACC_FINAL)||
       !(cc->cff.access_flags&ACC_FINAL)||wc->jloader!=font_class->jloader||
       dc->jloader!=font_class->jloader||cc->jloader!=font_class->jloader||
       g->mb.clazz->jloader!=api->jloader)return 0;
    if(!jbr_bref(cc,c,"b","Lmain/c;",d,0)||
       !jbr_bref(cc,NULL,"a","Lmain/b;",c,1)||
       !jbr_bref(dc,d,"aj","Lt;",wrapper,0)||
       !jbr_bref(wc,wrapper,"a",graphics_desc,g,0)||
       !jbr_bref(api,c,"graphics",graphics_desc,g,0)||
       !jbr_bzero(api,c,"treoUsesExplicitBuffer")||
       !jbr_bzero(g->mb.clazz,g,"ownsContext")||
       !jbr_bzero(g->mb.clazz,g,"treoPixelDependent")||
       !jbr_bzero(g->mb.clazz,g,"headless"))return 0;
    int64_t cctx=0,gctx=0;
    if(!jbr_bcontext(api,c,&cctx)||!jbr_bcontext(g->mb.clazz,g,&gctx)||cctx!=gctx)return 0;
    out->wrapper=wrapper;out->canvas=c;out->graphics=g;out->context=cctx;
    return 1;
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
