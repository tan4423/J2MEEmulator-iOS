/* Single-process, single-VM research backend. SDL owns presentation on main.
 * Java threads own execution; a native lock protects surfaces and event queue.
 * No runtime pointer is retained in the method graph. No game JAR rewriting. */
#include <SDL2/SDL.h>
#include <cairo.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <time.h>
#include <limits.h>
#include <stddef.h>
#include "jvm.h"
#include "jvm_util.h"
#include "garbage.h"
#include "arraylist.h"
#include "mbedtls/sha256.h"
#include "jarbox_residual_build_identity.h"
#include "jarbox_desktop_tier.h"
#include "jarbox_world_observer.h"

extern void treo_vm_paint_sample_reset(void);
extern void treo_vm_paint_sample_begin(void);
extern int treo_vm_paint_sample_end(void);
extern const char *treo_vm_paint_sample_report(void);

enum { MAX_SURF=8192, MAX_DIM=8192, MAX_SCREEN=2048, MAX_EVENTS=256, MAX_EDGES=8192 };
typedef struct { cairo_surface_t *s; cairo_t *c; int image, mutable; uint64_t id; } Surface;
static Surface surfaces[MAX_SURF];
static unsigned next_slot=1;
static uint64_t generation=1;
static pthread_mutex_t lock=PTHREAD_MUTEX_INITIALIZER, graph_lock=PTHREAD_MUTEX_INITIALIZER;
static _Atomic int stop_requested, finished, failed;
static _Atomic uint64_t paints, paint_cpu, frames, draw_calls, image_allocs, events_delivered, gc_cycles, gc_cpu, gc_aborts, gc_heap_sample;
static pthread_mutex_t vm_lock=PTHREAD_MUTEX_INITIALIZER;
static MiniJVM *active_vm;
static const char *trace_path;
static int frame_w,frame_h, dirty, show_canvas=1;
static uint32_t *frame;
static unsigned long long native_bytes;
_Atomic int jarbox_lab_trace_enabled;
int jarbox_lab_effect_enabled;
static int trace_graph; // launch profile, immutable after startup
enum { EFFECT_CAP=4096 };
typedef struct {uint64_t seq,mono;unsigned worker;int pc,write,value;char method[192];} Effect;
static Effect effects[EFFECT_CAP],effect_snapshot[EFFECT_CAP];
static uint64_t effect_seq,effect_exported,effect_lost;
static _Atomic unsigned next_worker;
static _Thread_local unsigned worker_id;
static FILE *effect_file;
static int fixture_ui, logic_mode;
int jarbox_lab_test_monitors;
static int sink_admitted,sink_fixture,map_fixture;
_Atomic int jarbox_lab_sink_requested;
#define sink_requested jarbox_lab_sink_requested
static _Atomic int sink_invalid;
int jarbox_lab_dispatch_fixture; /* immutable after launch, fixture only */
extern uint64_t jarbox_desktop_direct_method_batches(void);
static _Atomic uint64_t sink_paints,sink_draws,sink_faults;
static _Thread_local s64 sink_context;
static _Thread_local uint64_t sink_draw_pending;
static _Atomic uint64_t deep_counts[18];
static _Thread_local uint64_t deep_pending[18];
static _Atomic int vector_requested,array_lookup_requested;
static _Atomic uint64_t live_counts[3];
void jarbox_lab_liveness_note(unsigned kind){
    if(kind<3)atomic_fetch_add_explicit(&live_counts[kind],1,memory_order_relaxed);
}
static int deep_admitted;
static _Atomic uint64_t world_state;
/* Exact Nick JAR + boot/API identities already admitted before VM starts.
 * Observe actual committed Java PUTSTATIC writes. Never initialize a class,
 * call Java, change a field or inspect arbitrary heap objects. */
void jarbox_lab_world_write(FieldInfo *fi,int zone,unsigned value){
    if(!deep_admitted||sink_fixture||fixture_ui||!fi||!fi->_this_class)return;
    if(!utf8_equals_c(fi->name,zone?"l4":"o4")||
       !utf8_equals_c(fi->descriptor,zone?"B":"S")||
       !utf8_equals_c(fi->_this_class->name,"Class_hii"))return;
    uint64_t old=atomic_load_explicit(&world_state,memory_order_relaxed),next;
    do {
        next=jwo_update(old,zone,value);
        if(next==old)return;
    } while(!atomic_compare_exchange_weak_explicit(&world_state,&old,next,memory_order_release,memory_order_relaxed));
    fprintf(stderr,"LAB_WORLD epoch=%llu map=%d zone=%d field=%s\n",(unsigned long long)jwo_epoch(next),jwo_map(next),jwo_zone(next),zone?"zone":"map");
}
static _Atomic uint64_t native4_count;
void jarbox_lab_native4_note(uint64_t n){atomic_fetch_add_explicit(&native4_count,n,memory_order_relaxed);}
static _Atomic uint64_t outside_ir_spans,outside_ir_ops;
int jarbox_lab_logic_ir_enabled(void){
    return deep_admitted&&!sink_fixture&&!fixture_ui&&!atomic_load(&sink_invalid)&&
        !atomic_load(&stop_requested)&&jarbox_desktop_logic_ir_mode(atomic_load(&sink_requested));
}
void jarbox_lab_logic_ir_note(uint64_t spans,uint64_t ops){
    atomic_fetch_add_explicit(&outside_ir_spans,spans,memory_order_relaxed);
    atomic_fetch_add_explicit(&outside_ir_ops,ops,memory_order_relaxed);
}
static _Atomic uint64_t gc_index_passes,gc_index_entries,gc_index_fallbacks;
int jarbox_lab_gc_index_admit(void){
#if defined(JARBOX_GC_DEFERRED_INDEX_EXPERIMENT) && JARBOX_GC_DEFERRED_INDEX_EXPERIMENT
    return deep_admitted&&!sink_fixture&&!fixture_ui;
#else
    return 0;
#endif
}
void jarbox_lab_gc_index_note(int indexed,size_t entries){
    if(indexed){atomic_fetch_add(&gc_index_passes,1);atomic_fetch_add(&gc_index_entries,entries);}
    else if(jarbox_lab_gc_index_admit())atomic_fetch_add(&gc_index_fallbacks,1);
}
int jarbox_lab_vector_enabled(void){return deep_admitted&&atomic_load_explicit(&vector_requested,memory_order_relaxed);}
int jarbox_lab_sink_level(int64_t context){
    if(!sink_context||(context&&context!=sink_context)||!deep_admitted||atomic_load(&sink_invalid))return 0;
    return atomic_load_explicit(&sink_requested,memory_order_relaxed);
}
int jarbox_lab_array_lookup_enabled(void){
    return deep_admitted&&atomic_load_explicit(&array_lookup_requested,memory_order_relaxed)&&
        jarbox_lab_sink_level(0)==1;
}
void jarbox_lab_deep_note(unsigned kind,unsigned count){
    if(kind<18){
        if(sink_context)deep_pending[kind]+=count;
        else atomic_fetch_add_explicit(&deep_counts[kind],count,memory_order_relaxed);
    }
}
static void flush_deep_counts(void){
    for(unsigned i=0;i<18;i++)if(deep_pending[i]){
        atomic_fetch_add_explicit(&deep_counts[i],deep_pending[i],memory_order_relaxed);
        deep_pending[i]=0;
    }
}
void jarbox_lab_residual_fault(void){
    atomic_store(&sink_invalid,1);atomic_store(&sink_requested,0);atomic_store(&array_lookup_requested,0);
    atomic_fetch_add(&sink_faults,1);
}
static int sink_draw(s64 id){
    if(id>0&&id==sink_context){
        /* Batch this per-thread paint-local count; avoid one global atomic per
         * discarded draw. labEndPaint flushes it before publishing the paint. */
        sink_draw_pending++;
        return 1;
    }
    return 0;
}
static void sink_read(s64 id){
    if(id>0&&id==sink_context){
        atomic_store(&sink_invalid,1);atomic_store(&sink_requested,0);
        atomic_fetch_add(&sink_faults,1);
    }
}
static _Atomic uint64_t logic_plans, logic_spans, logic_ops;
static char *rt_path,*api_path,*game_path,*save_path;
static int width,height;
static int rc=1;
static FILE *trace;
typedef struct {int a,b,c,d;} Event;
static Event events[MAX_EVENTS];
static unsigned rd,wr;
static uint64_t event_overflow;
typedef struct {char from[192],to[192];uint64_t count;} Edge;
static Edge edges[MAX_EDGES];
static uint64_t graph_dropped;
static _Atomic uint64_t net_stages[32];
static uint64_t ns(clockid_t id) {
    struct timespec t;
    return clock_gettime(id,&t)?0:(uint64_t)t.tv_sec*1000000000ull+t.tv_nsec;
}
static int method_name(MethodInfo *m,char *out,size_t n) {
    if(!m||!m->_this_class||!m->_this_class->name||!m->name||!m->descriptor) return 0;
    int len=snprintf(out,n,"%s.%s%s",utf8_cstr(m->_this_class->name),
                     utf8_cstr(m->name),utf8_cstr(m->descriptor));
    return len>0 && (size_t)len<n;
}
void jarbox_lab_method_enter(MethodInfo *m,Runtime *parent) {
    if(!atomic_load_explicit(&jarbox_lab_trace_enabled,memory_order_relaxed)||!m||!parent) return;
    char a[192],b[192];
    if(!method_name(m,b,sizeof b)) return;
    if(!method_name(parent->method,a,sizeof a)) strcpy(a,"<entry>");
    /* Only edges touching the game; count all executed calls reaching this
       entry, not inlined/quickened leaf operations. */
    if(strncmp(a,"Class_",6)&&strncmp(b,"Class_",6)&&
       strncmp(a,"main/",5)&&strncmp(b,"main/",5)&&
       strncmp(a,"LabFixture",10)&&strncmp(b,"LabFixture",10)) return;
    uint32_t hash=2166136261u;
    for(const char *s=a;*s;s++)hash=(hash^(unsigned char)*s)*16777619u;
    for(const char *s=b;*s;s++)hash=(hash^(unsigned char)*s)*16777619u;
    pthread_mutex_lock(&graph_lock);
    for(unsigned i=0;i<MAX_EDGES;i++){
        Edge *e=&edges[(hash+i)&(MAX_EDGES-1)];
        if(!e->count){strcpy(e->from,a);strcpy(e->to,b);e->count=1;goto done;}
        if(!strcmp(e->from,a)&&!strcmp(e->to,b)){e->count++;goto done;}
    }
    graph_dropped++;
done: pthread_mutex_unlock(&graph_lock);
}
void jarbox_lab_int_field(Runtime *r,Instance *receiver,int offset,int value,int write){
    if(!jarbox_lab_effect_enabled||!r||!r->method||!receiver||!receiver->mb.clazz)return;
    MethodInfo *m=r->method;JClass *c=m->_this_class;
    if(!c||!c->name||(!utf8_equals_c(c->name,"Class_hda")&&!utf8_equals_c(c->name,"LabFixture$Probe")))return;
    /* A field offset is only meaningful inside the receiver's actual
       layout. Same numeric offsets in unrelated objects are not s6. */
    JClass *owner=receiver->mb.clazz;
    while(owner&&owner!=c)owner=owner->superclass;
    if(!owner)return;
    if(!m->converted_code||!m->converted_code->code||!r->pc)return;
    const unsigned char *code=(const unsigned char*)m->converted_code->code;
    const unsigned char *pc=(const unsigned char*)r->pc;
    if(pc<code||pc>=code+m->converted_code->code_length)return;
    int matched=0;
    for(int i=0;i<c->fieldPool.field_used;i++){
        FieldInfo *f=c->fieldPool.field+i;
        if(!(f->access_flags&8)&&f->name&&f->descriptor&&f->offset_instance==offset&&utf8_equals_c(f->name,"s6")&&utf8_equals_c(f->descriptor,"I")){matched=1;break;}
    }
    if(!matched)return;
    Effect e={0};if(!method_name(m,e.method,sizeof e.method))return;
    if(!worker_id)worker_id=atomic_fetch_add(&next_worker,1)+1;
    e.mono=ns(CLOCK_MONOTONIC);e.worker=worker_id;e.pc=(int)(pc-code);e.value=value;e.write=write;
    if(write&&e.pc==1424&&utf8_equals_c(m->name,"a0")&&utf8_equals_c(c->name,"Class_hda"))jarbox_lab_liveness_note(0);
    pthread_mutex_lock(&graph_lock);
    e.seq=++effect_seq;effects[(e.seq-1)%EFFECT_CAP]=e;
    pthread_mutex_unlock(&graph_lock);
}
static void flush_effects(void){
    if(!effect_file)return;
    pthread_mutex_lock(&graph_lock);
    uint64_t last=effect_seq,first=effect_exported+1;
    if(last>=first&&last-first+1>EFFECT_CAP){effect_lost+=last-first+1-EFFECT_CAP;first=last-EFFECT_CAP+1;}
    unsigned count=0;
    for(uint64_t seq=first;seq<=last;seq++)effect_snapshot[count++]=effects[(seq-1)%EFFECT_CAP];
    effect_exported=last;uint64_t lost=effect_lost;
    pthread_mutex_unlock(&graph_lock);
    for(unsigned i=0;i<count;i++){Effect*e=&effect_snapshot[i];
        fprintf(effect_file,"%llu,%llu,%u,%s,%d,%s,%d,%llu\n",(unsigned long long)e->seq,(unsigned long long)e->mono,
           e->worker,e->method,e->pc,e->write?"write":"read",e->value,(unsigned long long)lost);
    }
    fflush(effect_file);
}
static void unsupported(const char *name) {
    fprintf(stderr,"LAB_UNSUPPORTED: %s\n",name);
    atomic_store(&failed,1); atomic_store(&stop_requested,1);
}
#define I(n) (r->jnienv->localvar_getInt(r->localvar,(n)))
#define J(n) (r->jnienv->localvar_getLong_2slot(r->localvar,(n)))
#define R(n) (r->jnienv->localvar_getRefer(r->localvar,(n)))
#define PI(v) (r->jnienv->push_int(r->stack,(v)))
#define PJ(v) (r->jnienv->push_long(r->stack,(v)))
#define PR(v) (r->jnienv->push_ref(r->stack,(v)))
#define FN(n) static s32 n_##n(Runtime *r,JClass *unused)
#define OK return RUNTIME_STATUS_NORMAL
#define LOCK pthread_mutex_lock(&lock)
#define UNLOCK pthread_mutex_unlock(&lock)
static Surface *get(s64 h){
    if(h<=0)return NULL;
    unsigned slot=(unsigned)((uint64_t)h%MAX_SURF);
    Surface *s=&surfaces[slot];
    return slot&&s->s&&s->id==(uint64_t)h?s:NULL;
}
static int sw(Surface *s){return cairo_image_surface_get_width(s->s);}
static int sh(Surface *s){return cairo_image_surface_get_height(s->s);}
static int valid_size(int w,int h){return w>0&&h>0&&w<=MAX_DIM&&h<=MAX_DIM&&(uint64_t)w*h<=16u*1024u*1024u;}
static s64 add(cairo_surface_t *s,int image,int mut){
    if(!s||cairo_surface_status(s)!=CAIRO_STATUS_SUCCESS||
       !valid_size(cairo_image_surface_get_width(s),cairo_image_surface_get_height(s))||
       generation>(uint64_t)INT64_MAX/MAX_SURF-1){if(s)cairo_surface_destroy(s);return 0;}
    unsigned slot=0;
    for(unsigned i=0;i<MAX_SURF-1;i++){
        unsigned p=next_slot++;
        if(next_slot>=MAX_SURF)next_slot=1;
        if(!surfaces[p].s){slot=p;break;}
    }
    if(!slot){cairo_surface_destroy(s);return 0;}
    unsigned long long bytes=(unsigned long long)cairo_image_surface_get_stride(s)*cairo_image_surface_get_height(s);
    if(bytes>256ull*1024*1024-native_bytes){cairo_surface_destroy(s);return 0;}
    cairo_t *c=cairo_create(s);
    if(cairo_status(c)!=CAIRO_STATUS_SUCCESS){cairo_destroy(c);cairo_surface_destroy(s);return 0;}
    uint64_t id=generation++*MAX_SURF+slot;
    surfaces[slot]=(Surface){s,c,image,mut,id};
    native_bytes+=bytes;
    cairo_set_source_rgb(c,0,0,0);
    cairo_set_line_width(c,1); cairo_set_antialias(c,CAIRO_ANTIALIAS_NONE);
    cairo_select_font_face(c,"sans",CAIRO_FONT_SLANT_NORMAL,CAIRO_FONT_WEIGHT_NORMAL);
    cairo_set_font_size(c,14);
    if(image)atomic_fetch_add(&image_allocs,1);
    return id;
}
static void drop(s64 h){
    Surface *s=get(h);if(!s)return;
    native_bytes-=(unsigned long long)cairo_image_surface_get_stride(s->s)*sh(s);
    cairo_destroy(s->c);cairo_surface_destroy(s->s);memset(s,0,sizeof *s);
}
static s64 create(int w,int h,int image){
    if(!valid_size(w,h))return 0;
    cairo_surface_t *s=cairo_image_surface_create(CAIRO_FORMAT_ARGB32,w,h);
    s64 id=add(s,image,1);
    if(id){cairo_t *c=get(id)->c;cairo_set_source_rgb(c,1,1,1);cairo_paint(c);cairo_set_source_rgb(c,0,0,0);}
    return id;
}
static char *string_copy(Runtime *r,int slot){
    Instance *j=R(slot);if(!j)return NULL;
    Utf8String *u=utf8_create();if(!u)return NULL;
    r->jnienv->jstring_2_utf8(j,u,r);
    char *s=strdup(utf8_cstr(u));utf8_destroy(u);return s;
}
static int array_ok(Instance *a,int type){
    return a&&a->mb.type==MEM_TYPE_ARR&&a->mb.arr_type_index==type&&a->arr_body;
}
static int range(Instance *a,int off,int stride,int w,int h){
    if(!array_ok(a,DATATYPE_INT)||!valid_size(w,h))return 0;
    int64_t end=(int64_t)off+(int64_t)(h-1)*stride;
    int64_t lo=end<off?end:off,hi=end>off?end:off;
    return lo>=0&&hi+w<=a->arr_length;
}
static void anchor(int a,int w,int h,double *x,double *y){
    if(a&8)*x-=w;else if(a&1)*x-=w/2;
    if(a&32)*y-=h;else if(a&2)*y-=h/2;
}
static void blit(Surface *dst,cairo_surface_t *src,int w,int h,double x,double y){
    cairo_save(dst->c);cairo_rectangle(dst->c,x,y,w,h);cairo_clip(dst->c);
    cairo_set_source_surface(dst->c,src,x,y);
    cairo_pattern_set_filter(cairo_get_source(dst->c),CAIRO_FILTER_NEAREST);
    cairo_paint(dst->c);cairo_restore(dst->c);
    atomic_fetch_add(&draw_calls,1);
}
FN(createContext){LOCK;s64 id=create(I(0),I(1),0);UNLOCK;PJ(id);OK;}
FN(destroyContext){LOCK;Surface *s=get(J(0));if(s&&!s->image)drop(J(0));UNLOCK;OK;}
FN(createMutableImage){LOCK;s64 id=create(I(0),I(1),1);UNLOCK;PJ(id);OK;}
typedef struct {const unsigned char *p;size_t left;} Png;
static cairo_status_t png_read(void *v,unsigned char *out,unsigned n){
    Png *p=v;if(n>p->left)return CAIRO_STATUS_READ_ERROR;
    memcpy(out,p->p,n);p->p+=n;p->left-=n;return CAIRO_STATUS_SUCCESS;
}
FN(createImageFromData){
    Instance *a=R(0);int off=I(1),len=I(2);s64 id=0;
    if(array_ok(a,DATATYPE_BYTE)&&off>=0&&len>=24&&off<=a->arr_length&&len<=a->arr_length-off){
        const unsigned char *p=(unsigned char*)a->arr_body+off;
        /* Bound dimensions before handing the PNG to a decoder. */
        if(!memcmp(p,"\x89PNG\r\n\x1a\n",8)&&!memcmp(p+12,"IHDR",4)){
            uint32_t w=((uint32_t)p[16]<<24)|((uint32_t)p[17]<<16)|((uint32_t)p[18]<<8)|p[19];
            uint32_t h=((uint32_t)p[20]<<24)|((uint32_t)p[21]<<16)|((uint32_t)p[22]<<8)|p[23];
            if(w&&h&&w<=MAX_DIM&&h<=MAX_DIM&&(uint64_t)w*h<=16u*1024u*1024u){
                Png input={p,(size_t)len};LOCK;
                id=add(cairo_image_surface_create_from_png_stream(png_read,&input),1,0);
                UNLOCK;
            }
        }
    }
    if(!id)fprintf(stderr,"LAB_IMAGE_REFUSED: unsupported/invalid/over-budget image\n");
    PJ(id);OK;
}
FN(destroyImage){LOCK;Surface *s=get(J(0));if(s&&s->image)drop(J(0));UNLOCK;OK;}
FN(getImageWidth){LOCK;Surface*s=get(J(0));int v=s?sw(s):0;UNLOCK;PI(v);OK;}
FN(getImageHeight){LOCK;Surface*s=get(J(0));int v=s?sh(s):0;UNLOCK;PI(v);OK;}
FN(getImageContext){LOCK;Surface*s=get(J(0));s64 v=s&&s->image&&s->mutable?J(0):0;UNLOCK;PJ(v);OK;}
FN(setColor){LOCK;Surface*s=get(J(0));uint32_t v=I(2);if(s)cairo_set_source_rgb(s->c,((v>>16)&255)/255.,((v>>8)&255)/255.,(v&255)/255.);UNLOCK;OK;}
FN(setClip){LOCK;Surface*s=get(J(0));if(s){cairo_reset_clip(s->c);cairo_rectangle(s->c,I(2),I(3),I(4)>0?I(4):0,I(5)>0?I(5):0);cairo_clip(s->c);}UNLOCK;OK;}
FN(setStrokeStyle){LOCK;Surface*s=get(J(0));if(s){double d[]={1,1};cairo_set_dash(s->c,d,I(2)==1?2:0,0);}UNLOCK;OK;}
FN(fillRect){if(sink_draw(J(0)))OK;LOCK;Surface*s=get(J(0));if(s&&I(4)>0&&I(5)>0){cairo_rectangle(s->c,I(2),I(3),I(4),I(5));cairo_fill(s->c);atomic_fetch_add(&draw_calls,1);}UNLOCK;OK;}
FN(drawRect){if(sink_draw(J(0)))OK;LOCK;Surface*s=get(J(0));if(s&&I(4)>=0&&I(5)>=0){cairo_rectangle(s->c,I(2)+.5,I(3)+.5,I(4),I(5));cairo_stroke(s->c);atomic_fetch_add(&draw_calls,1);}UNLOCK;OK;}
FN(drawLine){if(sink_draw(J(0)))OK;LOCK;Surface*s=get(J(0));if(s){cairo_move_to(s->c,I(2)+.5,I(3)+.5);cairo_line_to(s->c,I(4)+.5,I(5)+.5);cairo_stroke(s->c);atomic_fetch_add(&draw_calls,1);}UNLOCK;OK;}
FN(setFont){LOCK;Surface*s=get(J(0));if(s){int style=I(3),size=I(4);cairo_select_font_face(s->c,I(2)==32?"monospace":"sans",style&2?CAIRO_FONT_SLANT_ITALIC:CAIRO_FONT_SLANT_NORMAL,style&1?CAIRO_FONT_WEIGHT_BOLD:CAIRO_FONT_WEIGHT_NORMAL);cairo_set_font_size(s->c,size==8?10:size==16?18:14);}UNLOCK;OK;}
FN(getStringWidth){char*t=string_copy(r,2);int v=0;LOCK;Surface*s=get(J(0));if(s&&t){cairo_text_extents_t e;cairo_text_extents(s->c,t,&e);v=(int)ceil(e.x_advance);}UNLOCK;free(t);PI(v);OK;}
FN(getFontHeight){int v=14;LOCK;Surface*s=get(J(0));if(s){cairo_font_extents_t e;cairo_font_extents(s->c,&e);v=(int)ceil(e.ascent+e.descent);}UNLOCK;PI(v);OK;}
FN(getFontAscent){int v=11;LOCK;Surface*s=get(J(0));if(s){cairo_font_extents_t e;cairo_font_extents(s->c,&e);v=(int)ceil(e.ascent);}UNLOCK;PI(v);OK;}
FN(drawString){if(sink_draw(J(0)))OK;char*t=string_copy(r,2);LOCK;Surface*s=get(J(0));if(s&&t){cairo_text_extents_t e;cairo_font_extents_t f;cairo_text_extents(s->c,t,&e);cairo_font_extents(s->c,&f);double x=I(3),y=I(4);int a=I(5);anchor(a,(int)ceil(e.x_advance),(int)ceil(f.ascent+f.descent),&x,&y);if(!(a&64))y+=f.ascent;cairo_move_to(s->c,x,y);cairo_show_text(s->c,t);atomic_fetch_add(&draw_calls,1);}UNLOCK;free(t);OK;}
/* MIDP uses positive counterclockwise angles in screen coordinates. */
static void arc_path(cairo_t*c,double x,double y,double w,double h,int start,int sweep,int fill){
    if(w<=0||h<=0||!sweep)return;
    if(sweep>360)sweep=360;if(sweep< -360)sweep=-360;
    double a=-start*(M_PI/180.0),b=a-sweep*(M_PI/180.0);
    cairo_new_path(c);cairo_save(c);
    cairo_translate(c,x+w/2,y+h/2);cairo_scale(c,w/2,h/2);
    if(fill)cairo_move_to(c,0,0);
    if(sweep>0)cairo_arc_negative(c,0,0,1,a,b);else cairo_arc(c,0,0,1,a,b);
    if(fill)cairo_close_path(c);cairo_restore(c);
    if(fill)cairo_fill(c);else cairo_stroke(c);
}
static void round_path(cairo_t*c,double x,double y,double w,double h,double aw,double ah,int fill){
    if(w<=0||h<=0)return;
    double rx=fmin(w,fmax(0,aw))/2,ry=fmin(h,fmax(0,ah))/2;
    cairo_new_path(c);
    if(rx==0||ry==0)cairo_rectangle(c,x,y,w,h);
    else{
        cairo_save(c);cairo_translate(c,x,y);cairo_scale(c,rx,ry);
        double xx=w/rx,yy=h/ry;
        cairo_arc(c,xx-1,1,1,-M_PI/2,0);
        cairo_arc(c,xx-1,yy-1,1,0,M_PI/2);
        cairo_arc(c,1,yy-1,1,M_PI/2,M_PI);
        cairo_arc(c,1,1,1,M_PI,3*M_PI/2);
        cairo_close_path(c);cairo_restore(c);
    }
    if(fill)cairo_fill(c);else cairo_stroke(c);
}
#define SHAPE(name,impl,fill) FN(name){if(sink_draw(J(0)))OK;LOCK;Surface*s=get(J(0));if(s){impl(s->c,I(2),I(3),I(4),I(5),I(6),I(7),fill);atomic_fetch_add(&draw_calls,1);}UNLOCK;OK;}
SHAPE(drawArc,arc_path,0)
SHAPE(fillArc,arc_path,1)
SHAPE(drawRoundRect,round_path,0)
SHAPE(fillRoundRect,round_path,1)
#undef SHAPE
static void polygon(Runtime*r,int fill){
    if(sink_draw(J(0)))return;
    Instance*x=R(2),*y=R(3);int n=I(4);
    if(n<(fill?3:2)||!array_ok(x,DATATYPE_INT)||!array_ok(y,DATATYPE_INT)||n>x->arr_length||n>y->arr_length)return;
    LOCK;Surface*s=get(J(0));
    if(s){s32*a=(s32*)x->arr_body,*b=(s32*)y->arr_body;cairo_new_path(s->c);cairo_move_to(s->c,a[0],b[0]);
        for(int i=1;i<n;i++)cairo_line_to(s->c,a[i],b[i]);
        cairo_close_path(s->c);if(fill)cairo_fill(s->c);else cairo_stroke(s->c);atomic_fetch_add(&draw_calls,1);}
    UNLOCK;
}
FN(fillPolygon){polygon(r,1);OK;}
FN(drawPolygon){polygon(r,0);OK;}
static uint32_t pixel(cairo_surface_t*s,int x,int y){
    uint32_t v;memcpy(&v,cairo_image_surface_get_data(s)+(size_t)y*cairo_image_surface_get_stride(s)+4*x,4);
    if(cairo_image_surface_get_format(s)==CAIRO_FORMAT_RGB24)v|=0xff000000u;
    return v;
}
static void put(cairo_surface_t*s,int x,int y,uint32_t v){memcpy(cairo_image_surface_get_data(s)+(size_t)y*cairo_image_surface_get_stride(s)+4*x,&v,4);}
static void region(Surface*d,Surface*s,int x,int y,int w,int h,int tr,double dx,double dy,int a){
    if(!d||!s||!valid_size(w,h)||x<0||y<0||x>sw(s)-w||y>sh(s)-h||tr<0||tr>7)return;
    int dw=tr>=4?h:w,dh=tr>=4?w:h;anchor(a,dw,dh,&dx,&dy);
    cairo_surface_flush(s->s);
    if(tr==0&&d!=s){
        cairo_save(d->c);cairo_rectangle(d->c,dx,dy,w,h);cairo_clip(d->c);
        cairo_set_source_surface(d->c,s->s,dx-x,dy-y);
        cairo_pattern_set_filter(cairo_get_source(d->c),CAIRO_FILTER_NEAREST);
        cairo_paint(d->c);cairo_restore(d->c);atomic_fetch_add(&draw_calls,1);return;
    }
    cairo_surface_t *tmp=cairo_image_surface_create(CAIRO_FORMAT_ARGB32,dw,dh);
    if(cairo_surface_status(tmp)!=CAIRO_STATUS_SUCCESS){cairo_surface_destroy(tmp);unsupported("region allocation");return;}
    for(int j=0;j<h;j++)for(int i=0;i<w;i++){
        int u=i,v=j;
        switch(tr){case 1:v=h-1-j;break;case 2:u=w-1-i;break;case 3:u=w-1-i;v=h-1-j;break;
        case 4:u=j;v=i;break;case 5:u=h-1-j;v=i;break;case 6:u=j;v=w-1-i;break;case 7:u=h-1-j;v=w-1-i;break;}
        put(tmp,u,v,pixel(s->s,x+i,y+j));
    }
    cairo_surface_mark_dirty(tmp);blit(d,tmp,dw,dh,dx,dy);cairo_surface_destroy(tmp);
}
FN(drawImage){sink_read(J(2));if(sink_draw(J(0)))OK;LOCK;Surface*d=get(J(0)),*s=get(J(2));if(s)region(d,s,0,0,sw(s),sh(s),0,I(4),I(5),I(6));UNLOCK;OK;}
FN(drawRegion){sink_read(J(2));if(sink_draw(J(0)))OK;LOCK;region(get(J(0)),get(J(2)),I(4),I(5),I(6),I(7),I(8),I(9),I(10),I(11));UNLOCK;OK;}
FN(copyArea){sink_read(J(0));LOCK;Surface*s=get(J(0));region(s,s,I(2),I(3),I(4),I(5),0,I(6),I(7),0);UNLOCK;OK;}
static uint32_t premul(uint32_t v){unsigned a=v>>24;return (a<<24)|((((v>>16)&255)*a+127)/255<<16)|((((v>>8)&255)*a+127)/255<<8)|((v&255)*a+127)/255;}
FN(drawRGB){if(sink_draw(J(0)))OK;Instance*a=R(2);int o=I(3),stride=I(4),w=I(7),h=I(8);if(range(a,o,stride,w,h)){LOCK;Surface*s=get(J(0));if(s){cairo_surface_t*t=cairo_image_surface_create(CAIRO_FORMAT_ARGB32,w,h);if(cairo_surface_status(t)==CAIRO_STATUS_SUCCESS){for(int y=0;y<h;y++)for(int x=0;x<w;x++){uint32_t v=((uint32_t*)a->arr_body)[(int64_t)o+(int64_t)y*stride+x];put(t,x,y,I(9)?premul(v):v|0xff000000u);}cairo_surface_mark_dirty(t);blit(s,t,w,h,I(5),I(6));}else unsupported("drawRGB allocation");cairo_surface_destroy(t);}UNLOCK;}OK;}
FN(getImageRGB){sink_read(J(0));Instance*a=R(2);int o=I(3),stride=I(4),x=I(5),y=I(6),w=I(7),h=I(8);if(range(a,o,stride,w,h)){LOCK;Surface*s=get(J(0));if(s&&x>=0&&y>=0&&x<=sw(s)-w&&y<=sh(s)-h){cairo_surface_flush(s->s);for(int j=0;j<h;j++)for(int i=0;i<w;i++)((uint32_t*)a->arr_body)[(int64_t)o+(int64_t)j*stride+i]=pixel(s->s,x+i,y+j);}UNLOCK;}OK;}
FN(flushToScreen){if(sink_draw(J(0)))OK;LOCK;Surface*s=get(J(0));if(s&&show_canvas&&sw(s)==width&&sh(s)==height){cairo_surface_flush(s->s);for(int y=0;y<height;y++)memcpy(frame+(size_t)y*width,cairo_image_surface_get_data(s->s)+(size_t)y*cairo_image_surface_get_stride(s->s),(size_t)width*4);dirty=1;atomic_fetch_add(&frames,1);}UNLOCK;OK;}
FN(profilePaintBegin){treo_vm_paint_sample_begin();PJ(ns(CLOCK_THREAD_CPUTIME_ID));OK;}
FN(profilePaintEnd){int sampled=treo_vm_paint_sample_end();flush_deep_counts();uint64_t e=ns(CLOCK_THREAD_CPUTIME_ID),b=J(0);if(b&&e>=b){atomic_fetch_add(&paints,1);atomic_fetch_add(&paint_cpu,e-b);treo_vm_paint_sample_note_duration(sampled,e-b);}OK;}
FN(isStopRequested){PI(atomic_load(&stop_requested));OK;}
FN(pollInputEvent){
    Event e;int found=0;LOCK;if(rd!=wr){e=events[rd++%MAX_EVENTS];found=1;}UNLOCK;
    if(!found){PR(NULL);OK;}
    Instance*a=jarray_create_by_type_index(r,4,DATATYPE_INT);
    if(a){s32 *p=(s32*)a->arr_body;p[0]=e.a;p[1]=e.b;p[2]=e.c;p[3]=e.d;atomic_fetch_add(&events_delivered,1);}else unsupported("input allocation");
    PR(a);OK;
}
FN(netTraceStage){int stage=I(0);if(stage>=0&&stage<32)atomic_fetch_add(&net_stages[stage],1);OK;}
FN(startupPhase){fprintf(stderr,"LAB_STARTUP phase=%d ns=%lld\n",I(0),(long long)J(1));OK;}
FN(reportLaunchError){/* Do not persist exception strings that may contain credentials. */unsupported("MIDlet launch/lifecycle failure");OK;}
/* These hooks describe the explicitly selected compatible/full-paint baseline.
   No headless authorization is granted by the lab. */
FN(zero){PI(0);OK;}
FN(zero_long){PJ(0);OK;}
FN(noop){OK;}
/* Reuse Canvas's existing full-repaint Core eligibility and paintLock.
 * Java paint, graphics state, image raster and pixel queries stay live.
 * A screen pixel dependency invalidates the experimental sample, not a
 * claimed successful fallback after irreversible discarded draws. */
FN(labPaintPolicy){PI(atomic_load(&sink_requested)&&!atomic_load(&sink_invalid)?1:0);OK;}
FN(labCorePaint){PI(sink_admitted&&atomic_load(&sink_requested)&&!atomic_load(&sink_invalid));OK;}
FN(labBeginPaint){
    s64 previous=sink_context; sink_context=0;
    if(I(2)&&sink_admitted&&!atomic_load(&sink_invalid)){
        LOCK;Surface*s=get(J(0));if(s&&!s->image&&sw(s)==width&&sh(s)==height)sink_context=J(0);UNLOCK;
    }
    PJ(previous);OK;
}
FN(labEndPaint){
    flush_deep_counts();
    if(sink_context){
        uint64_t draws=sink_draw_pending;
        if(draws){
            atomic_fetch_add_explicit(&sink_draws,draws,memory_order_relaxed);
            sink_draw_pending=0;
        }
        atomic_fetch_add(&sink_paints,1);
    }
    sink_context=J(0);OK;
}
FN(labCoreResult){
    if(I(0)!=0){atomic_store(&sink_invalid,1);atomic_store(&sink_requested,0);atomic_store(&array_lookup_requested,0);atomic_fetch_add(&sink_faults,1);}
    OK;
}
#include "lab_ui.h"
FN(unavailable){unsupported("native bridge operation outside supported 2D subset");return RUNTIME_STATUS_ERROR;}
#define CLS "javax/microedition/lcdui/NativeBridge"
#define N(name,desc,fn) {CLS,#name,desc,n_##fn}
static java_native_method methods[]={
 N(createContext,"(II)J",createContext),N(destroyContext,"(J)V",destroyContext),N(flushToScreen,"(J)V",flushToScreen),
 N(createMutableImage,"(II)J",createMutableImage),N(createImageFromData,"([BII)J",createImageFromData),N(destroyImage,"(J)V",destroyImage),
 N(getImageWidth,"(J)I",getImageWidth),N(getImageHeight,"(J)I",getImageHeight),N(getImageContext,"(J)J",getImageContext),
 N(setColor,"(JI)V",setColor),N(setClip,"(JIIII)V",setClip),N(setStrokeStyle,"(JI)V",setStrokeStyle),
 N(drawLine,"(JIIII)V",drawLine),N(fillRect,"(JIIII)V",fillRect),N(drawRect,"(JIIII)V",drawRect),
 N(drawArc,"(JIIIIII)V",drawArc),N(fillArc,"(JIIIIII)V",fillArc),N(drawRoundRect,"(JIIIIII)V",drawRoundRect),N(fillRoundRect,"(JIIIIII)V",fillRoundRect),
 N(fillPolygon,"(J[I[II)V",fillPolygon),N(drawPolygon,"(J[I[II)V",drawPolygon),
 N(drawImage,"(JJIII)V",drawImage),N(drawRegion,"(JJIIIIIIII)V",drawRegion),N(copyArea,"(JIIIIII)V",copyArea),
 N(drawRGB,"(J[IIIIIIII)V",drawRGB),N(getImageRGB,"(J[IIIIIII)V",getImageRGB),
 N(setFont,"(JIII)V",setFont),N(drawString,"(JLjava/lang/String;III)V",drawString),
 N(getStringWidth,"(JLjava/lang/String;)I",getStringWidth),N(getFontHeight,"(J)I",getFontHeight),N(getFontAscent,"(J)I",getFontAscent),
 N(profilePaintBegin,"()J",profilePaintBegin),N(profilePaintEnd,"(J)V",profilePaintEnd),
 N(pollInputEvent,"()[I",pollInputEvent),N(isStopRequested,"()Z",isStopRequested),
 N(startupPhase,"(IJ)V",startupPhase),N(reportLaunchError,"(Ljava/lang/String;)V",reportLaunchError),
 N(afkBufferBlitBegin,"(IIZ)J",zero_long),N(afkBufferBlitEnd,"(J)V",noop),
 N(afkSuspended,"()Z",zero),N(takeAfkRefresh,"()I",zero),N(afkPaintPolicy,"()I",labPaintPolicy),
 N(ninjaDeepActive,"()Z",zero),N(ninjaDeepSkip,"(Ljava/lang/Object;I)Z",zero),
 N(ninjaCorePaint,"(Ljava/lang/Object;)Z",labCorePaint),N(ninjaCorePaintResult,"(I)V",labCoreResult),
 N(afkImageCacheEnabled,"()Z",zero),N(imageCacheNote,"(II)V",noop),N(afkCanvasResult,"(I)V",noop),
 N(afkBypassPaint,"()Z",zero),N(beginAfkPaint,"(JZ)J",labBeginPaint),N(endAfkPaint,"(J)V",labEndPaint),
 N(displayWaitEnabled,"()Z",zero),N(displayWaitVersion,"()I",zero),N(displayWaitIfUnchanged,"(II)I",zero),N(displayWake,"()V",noop),N(jarSparsePaintDue,"()Z",zero),
 N(lockScreen,"()V",noop),N(unlockScreen,"()V",noop),N(screenRevision,"()I",screenRevision),
 N(formBegin,"(Ljava/lang/String;I)V",formBegin),N(formAddCommand,"(Ljava/lang/String;III)V",formAddCommand),
 N(formAddStringItem,"(Ljava/lang/String;Ljava/lang/String;I)V",formAddStringItem),
 N(formAddTextField,"(Ljava/lang/String;Ljava/lang/String;II)V",formAddTextField),
 N(formAddChoice,"(Ljava/lang/String;I)V",formAddChoice),N(formAddChoiceOption,"(Ljava/lang/String;)V",formAddChoiceOption),
 N(listAddItem,"(Ljava/lang/String;)V",listAddItem),N(listSetLastIcon,"(J)V",listSetLastIcon),N(setListType,"(I)V",setListType),
 N(setAlertText,"(Ljava/lang/String;I)V",setAlertText),N(takeText,"(II)[C",takeText),
 N(formShow,"()V",formShow),N(showCanvas,"()V",showCanvas),N(netTraceStage,"(I)V",netTraceStage),
 N(vibrate,"(I)V",noop)
};
/* Refuse unknown archives rather than applying an experimental profile.
 * The fixture exception is already constrained to SDL dummy and loopback. */
static int file_digest_matches(const char *path,const unsigned char expected[32]);
static int nick_archive(const char *path){
    static const unsigned char expected[32]={
        0x11,0xb1,0xd4,0xc1,0x1f,0x90,0x82,0xb9,0xd0,0x7b,0xc7,0xbd,0x92,0xa9,0xad,0x3a,
        0xba,0xd4,0x07,0x64,0x85,0x3e,0x23,0x68,0x6c,0xc8,0x66,0x86,0x86,0x9c,0x96,0x6c};
    return file_digest_matches(path,expected);
}
static int file_digest_matches(const char *path,const unsigned char expected[32]){
    FILE *f=fopen(path,"rb");if(!f)return 0;
    mbedtls_sha256_context ctx;unsigned char buf[16384],digest[32];size_t n;
    mbedtls_sha256_init(&ctx);mbedtls_sha256_starts(&ctx,0);
    while((n=fread(buf,1,sizeof buf,f)))mbedtls_sha256_update(&ctx,buf,n);
    int ok=!ferror(f);fclose(f);
    mbedtls_sha256_finish(&ctx,digest);mbedtls_sha256_free(&ctx);
    return ok&&!memcmp(expected,digest,32);
}
static void sample_vm_gc(MiniJVM *vm){
    if(!vm)return;
    atomic_store(&logic_plans,__atomic_load_n(&vm->block_ir_plans,__ATOMIC_RELAXED));
    atomic_store(&logic_spans,__atomic_load_n(&vm->desktop_block_ir_spans,__ATOMIC_RELAXED));
    atomic_store(&logic_ops,__atomic_load_n(&vm->desktop_block_ir_ops,__ATOMIC_RELAXED));
    atomic_store(&gc_cycles,__atomic_load_n(&vm->session->treo_state.gc_worker_cycles,__ATOMIC_RELAXED));
    atomic_store(&gc_cpu,__atomic_load_n(&vm->session->treo_state.gc_worker_cpu_ns,__ATOMIC_RELAXED));
    atomic_store(&gc_aborts,__atomic_load_n(&vm->session->treo_state.gc_worker_aborts,__ATOMIC_RELAXED));
    uint64_t sample=__atomic_load_n(&vm->collector->jarbox_status_heap_sample,__ATOMIC_ACQUIRE);
    if(sample)atomic_store(&gc_heap_sample,sample-1);
}
static void *run_vm(void *unused){
    MiniJVM *vm=jvm_create(); if(!vm)goto done;
    if(!jarbox_native_heap_register_vm(vm)){
        jarbox_session_begin_stop(vm->session);(void)jarbox_session_mark_dead(vm->session);
        jarbox_session_release(vm->session);jvm_free(vm);goto done;
    }
    uint64_t key=jarbox_native_heap_key_for_vm(vm);
    vm->desktop_block_ir_enabled=logic_mode;
    vm->desktop_block_ir_fixture=fixture_ui;
    vm->jdwp_enable=0;vm->jdwp_suspend_on_start=0;vm->max_heap_size=128*1024*1024;
    vm->garbage_collect_period_ms=500;vm->heap_overload_percent=70;
    size_t len=strlen(api_path)+strlen(game_path)+2;char *cp=malloc(len);
    if(!cp)abort();snprintf(cp,len,"%s:%s",api_path,game_path);
    if(!jvm_init(vm,rt_path,cp)){
        native_reg_lib(vm,methods,sizeof methods/sizeof methods[0]);
        sys_properties_set_c(vm,"os.name","iOS"); /* match game-facing profile, not host OS */
        sys_properties_set_c(vm,"app.save.root",save_path);
        sys_properties_set_c(vm,"microedition.platform","Apple/iPhone");
        sys_properties_set_c(vm,"microedition.encoding","UTF-8");sys_properties_set_c(vm,"microedition.locale","en");
        sys_properties_set_c(vm,"microedition.profiles","MIDP-2.0");sys_properties_set_c(vm,"microedition.configuration","CLDC-1.1");
        char w[16],h[16];snprintf(w,sizeof w,"%d",width);snprintf(h,sizeof h,"%d",height);
        sys_properties_set_c(vm,"j2me.screen.width",w);sys_properties_set_c(vm,"j2me.screen.height",h);
        if(getenv("JARBOX_LAB_UI_FIXTURE")&&getenv("JARBOX_LAB_TEST_PORT"))
            sys_properties_set_c(vm,"jarbox.lab.test.port",getenv("JARBOX_LAB_TEST_PORT"));
        if(fixture_ui&&getenv("JARBOX_LAB_TEST_CONTROL"))sys_properties_set_c(vm,"jarbox.lab.test.control","1");
        if(sink_fixture)sys_properties_set_c(vm,"jarbox.lab.test.sink","1");
        if(map_fixture)sys_properties_set_c(vm,"jarbox.lab.test.map","1");
        (void)jarbox_session_enter_foreground(vm->session);
        pthread_mutex_lock(&vm_lock);active_vm=vm;pthread_mutex_unlock(&vm_lock);
        ArrayList *args=arraylist_create(0);arraylist_push_back(args,game_path);
        rc=call_main(vm,"javax/microedition/shell/MIDletRunner",args);arraylist_destroy(args);
        pthread_mutex_lock(&vm_lock);
        sample_vm_gc(vm);
        active_vm=NULL;
        pthread_mutex_unlock(&vm_lock);
    }
    free(cp);
    vm->collector->exit_flag=1;jarbox_session_begin_stop(vm->session);
    gc_request_thread_status(vm->collector,GARBAGE_THREAD_STOP);thread_stop_all(vm);
    jvm_destroy(vm);jarbox_native_heap_unregister_key(key);
done:atomic_store(&finished,1);return NULL;
}
static void enqueue(Event e){LOCK;if(wr-rd>=MAX_EVENTS){event_overflow++;unsupported("input queue overflow");}else events[wr++%MAX_EVENTS]=e;UNLOCK;}
static int keycode(SDL_Keycode k){
    switch(k){case SDLK_UP:return -1;case SDLK_DOWN:return -2;case SDLK_LEFT:return -3;case SDLK_RIGHT:return -4;case SDLK_RETURN:return -5;case SDLK_F1:return -6;case SDLK_F2:return -7;case SDLK_ASTERISK:return 42;case SDLK_HASH:return 35;default:return k>=SDLK_0&&k<=SDLK_9?k:0;}
}
#include "lab_control.h"
static void sample(void){
    pthread_mutex_lock(&vm_lock);
    if(active_vm)sample_vm_gc(active_vm);
    pthread_mutex_unlock(&vm_lock);
    LOCK;unsigned long long bytes=native_bytes;UNLOCK;
    fprintf(trace,"%llu,%llu,%llu,%llu,%llu,%llu,%llu,%llu,%llu,%llu,%llu,%llu,%llu,%s,%d,%llu,%llu,%llu,%d",
        (unsigned long long)ns(CLOCK_MONOTONIC),(unsigned long long)ns(CLOCK_PROCESS_CPUTIME_ID),
        (unsigned long long)atomic_load(&paints),(unsigned long long)atomic_load(&paint_cpu),
        (unsigned long long)atomic_load(&frames),(unsigned long long)atomic_load(&draw_calls),
        (unsigned long long)atomic_load(&image_allocs),(unsigned long long)atomic_load(&events_delivered),
        (unsigned long long)atomic_load(&gc_cycles),(unsigned long long)atomic_load(&gc_cpu),
        bytes,(unsigned long long)atomic_load(&gc_aborts),(unsigned long long)atomic_load(&gc_heap_sample),logic_mode?"logic":trace_graph?"graph":"plain",atomic_load(&sink_requested),(unsigned long long)atomic_load(&sink_paints),(unsigned long long)atomic_load(&sink_draws),(unsigned long long)atomic_load(&sink_faults),atomic_load(&sink_invalid));
    for(unsigned i=0;i<18;i++)fprintf(trace,",%llu",(unsigned long long)atomic_load(&deep_counts[i]));
    fprintf(trace,",%d,%llu,%llu,%llu,%llu,%llu,%llu",atomic_load(&jarbox_lab_trace_enabled),(unsigned long long)atomic_load(&logic_plans),(unsigned long long)atomic_load(&logic_spans),(unsigned long long)atomic_load(&logic_ops),(unsigned long long)atomic_load(&live_counts[0]),(unsigned long long)atomic_load(&live_counts[1]),(unsigned long long)atomic_load(&live_counts[2]));
    fprintf(trace,",%d,%llu,%llu,%llu",jarbox_lab_gc_index_admit(),(unsigned long long)atomic_load(&gc_index_passes),(unsigned long long)atomic_load(&gc_index_entries),(unsigned long long)atomic_load(&gc_index_fallbacks));
    uint64_t world=atomic_load_explicit(&world_state,memory_order_acquire);
    fprintf(trace,",%llu,%llu,%llu,%d,%d,%llu,%llu\n",(unsigned long long)atomic_load(&outside_ir_spans),(unsigned long long)atomic_load(&outside_ir_ops),(unsigned long long)jarbox_desktop_direct_method_batches(),jwo_map(world),jwo_zone(world),(unsigned long long)jwo_epoch(world),(unsigned long long)atomic_load(&native4_count));fflush(trace);
}
static int write_graph(void){
    size_t len=strlen(trace_path)+32;char *p=malloc(len),*tmp=malloc(len);
    if(!p||!tmp){free(p);free(tmp);return 0;}
    snprintf(p,len,"%s.edges.tsv",trace_path);snprintf(tmp,len,"%s.edges.tmp",trace_path);
    FILE *f=fopen(tmp,"w");if(!f){free(p);free(tmp);return 0;}
    pthread_mutex_lock(&graph_lock);
    fprintf(f,"caller\tcallee\tcalls\n");for(unsigned i=0;i<MAX_EDGES;i++)if(edges[i].count)fprintf(f,"%s\t%s\t%llu\n",edges[i].from,edges[i].to,(unsigned long long)edges[i].count);
    uint64_t dropped=graph_dropped;pthread_mutex_unlock(&graph_lock);
    fprintf(f,"<overflow>\t<overflow>\t%llu\n",(unsigned long long)dropped);
    int ok=!fclose(f)&&!rename(tmp,p);if(!ok)remove(tmp);free(p);free(tmp);return ok;
}
extern void smoke_install_crash_handler(void);
int main(int argc,char**argv){
    if(argc!=9){fprintf(stderr,"usage: lab RT.jar API.jar GAME.jar SAVE_DIR TRACE.csv WIDTH HEIGHT graph|plain|logic\n");return 2;}
    rt_path=argv[1];api_path=argv[2];game_path=argv[3];save_path=argv[4];
    width=atoi(argv[6]);height=atoi(argv[7]);trace_graph=!strcmp(argv[8],"graph");
    atomic_store(&jarbox_lab_trace_enabled,trace_graph);jarbox_lab_effect_enabled=trace_graph;
    logic_mode=!strcmp(argv[8],"logic");
    if(!valid_size(width,height)||width>MAX_SCREEN||height>MAX_SCREEN||(!trace_graph&&!logic_mode&&strcmp(argv[8],"plain")))return 2;
    fixture_ui=getenv("JARBOX_LAB_UI_FIXTURE")&&strcmp(getenv("JARBOX_LAB_UI_FIXTURE"),"1")==0;
    jarbox_lab_test_monitors=getenv("JARBOX_LAB_TEST_MONITORS")&&strcmp(getenv("JARBOX_LAB_TEST_MONITORS"),"1")==0;
    if(fixture_ui&&(!getenv("SDL_VIDEODRIVER")||strcmp(getenv("SDL_VIDEODRIVER"),"dummy")||!strstr(game_path,"/fixture.jar")))return 2;
    jarbox_lab_dispatch_fixture=fixture_ui&&getenv("JARBOX_LAB_TEST_DISPATCH")&&strcmp(getenv("JARBOX_LAB_TEST_DISPATCH"),"1")==0;
    sink_fixture=fixture_ui&&getenv("JARBOX_LAB_TEST_SINK")!=NULL;
    sink_admitted=sink_fixture||nick_archive(game_path);
    map_fixture=sink_fixture&&getenv("JARBOX_LAB_TEST_MAP")&&strcmp(getenv("JARBOX_LAB_TEST_MAP"),"1")==0;
    deep_admitted=(map_fixture||(!sink_fixture&&sink_admitted))&&file_digest_matches(api_path,jbr_bundled_api_sha256)&&file_digest_matches(rt_path,jbr_bundled_boot_sha256);
    if(logic_mode&&!fixture_ui&&!sink_admitted){
        fprintf(stderr,"LAB_LOGIC_REFUSED unknown archive\n");return 2;
    }
    trace_path=argv[5];trace=fopen(trace_path,"w");if(!trace)return 2;
    treo_vm_paint_sample_reset();
    if(trace_graph){
        size_t n=strlen(trace_path)+24;char*p=malloc(n);if(!p)return 2;
        snprintf(p,n,"%s.effects.csv",trace_path);effect_file=fopen(p,"w");free(p);if(!effect_file)return 2;
        fprintf(effect_file,"sequence,monotonic_ns,worker,method,pc,operation,value,lost_total\n");
    }
    fprintf(trace,"monotonic_ns,process_cpu_ns,paints,paint_cpu_ns,frames,draw_calls,image_allocs,input_events,gc_cycles,gc_cpu_ns,native_surface_bytes,gc_aborts,gc_heap_sample_bytes,mode,sink_requested,sink_paints,sink_draws,sink_faults,sink_invalid,deep_leaves,glyph_attempts,glyph_scope_refusals,glyph_link_refusals,glyph_data_refusals,glyph_loops,glyph_chars,map_q3,map_m3,map_refusals,residual_plans,residual_calls,residual_regions,residual_deopts,map_layout_builds,map_layout_hits,vector_hits,vector_refusals,graph_enabled,ir_plans,ir_spans,ir_ops,skill_advances_live,network_calls_live,update_calls_live,gc_index_eligible,gc_index_passes,gc_index_entries,gc_index_fallbacks,ir_outside_spans,ir_outside_ops,direct_methods,java_map,java_zone,world_epoch,native4_spans\n");
    frame=calloc((size_t)width*height,4);if(!frame)return 2;
    if(SDL_Init(SDL_INIT_VIDEO|SDL_INIT_EVENTS)){fprintf(stderr,"%s\n",SDL_GetError());return 2;}
    SDL_Window *win=SDL_CreateWindow("JarBox Research Lab",SDL_WINDOWPOS_CENTERED,SDL_WINDOWPOS_CENTERED,width*2,height*2,SDL_WINDOW_RESIZABLE);
    SDL_Renderer *ren=win?SDL_CreateRenderer(win,-1,SDL_RENDERER_SOFTWARE):NULL;
    SDL_Texture *tex=ren?SDL_CreateTexture(ren,SDL_PIXELFORMAT_ARGB8888,SDL_TEXTUREACCESS_STREAMING,width,height):NULL;
    if(!tex){fprintf(stderr,"%s\n",SDL_GetError());return 2;}
    SDL_RenderSetLogicalSize(ren,width,height);
    smoke_install_crash_handler();pthread_t th;
    ctl_open();
    sample();if(pthread_create(&th,NULL,run_vm,NULL)){ctl_close();return 2;}
    uint64_t last=ns(CLOCK_MONOTONIC),last_graph=last,last_control=last,last_paint_report=last;
    int pointer_down=0;int pressed[512]={0};
    while(!atomic_load(&finished)){
        SDL_Event e;
        ui_tick();
        LOCK;int modal=!show_canvas;UNLOCK;
        if(fixture_ui&&modal){
            fixture_ui=0;
            if(!getenv("JARBOX_LAB_TEST_CONTROL")){
            SDL_Event input={0};input.type=SDL_TEXTINPUT;strcpy(input.text.text,"b");
            if(SDL_PushEvent(&input)!=1)unsupported("fixture text injection");
            input=(SDL_Event){0};input.type=SDL_KEYDOWN;input.key.keysym.sym=SDLK_F1;
            if(SDL_PushEvent(&input)!=1)unsupported("fixture command injection");
            }
        }
        if(modal&&!SDL_IsTextInputActive())SDL_StartTextInput();
        else if(!modal&&SDL_IsTextInputActive())SDL_StopTextInput();
        while(SDL_PollEvent(&e)){
            if(e.type==SDL_QUIT||(e.type==SDL_KEYDOWN&&e.key.keysym.sym==SDLK_ESCAPE)){atomic_store(&stop_requested,1);continue;}
            if(e.type==SDL_WINDOWEVENT&&e.window.event==SDL_WINDOWEVENT_FOCUS_LOST){
                for(unsigned i=0;i<512;i++)if(pressed[i]){enqueue((Event){4,0,0,pressed[i]});pressed[i]=0;}
                if(pointer_down){enqueue((Event){2,0,0,0});pointer_down=0;}
            }
            if(ui_handle_event(&e))continue;
            if(e.type==SDL_KEYDOWN||e.type==SDL_KEYUP){
                int k=keycode(e.key.keysym.sym),sc=e.key.keysym.scancode;
                if(k){if(sc>=0&&sc<512)pressed[sc]=e.type==SDL_KEYUP?0:k;
                    enqueue((Event){e.type==SDL_KEYUP?4:e.key.repeat?5:3,0,0,k});}
            }else if((e.type==SDL_MOUSEBUTTONDOWN||e.type==SDL_MOUSEBUTTONUP)&&e.button.button==SDL_BUTTON_LEFT){
                int x=e.button.x,y=e.button.y;
                /* SDL logical-size scales pointer events into the game area. */
                if(e.type==SDL_MOUSEBUTTONDOWN&&x>=0&&y>=0&&x<width&&y<height){pointer_down=1;enqueue((Event){0,x,y,0});}
                else if(e.type==SDL_MOUSEBUTTONUP&&pointer_down){pointer_down=0;enqueue((Event){2,x,y,0});}
            }else if(e.type==SDL_MOUSEMOTION&&pointer_down)enqueue((Event){1,e.motion.x,e.motion.y,0});
        }
        uint64_t control_now=ns(CLOCK_MONOTONIC);
        if(ctl_fd>=0&&control_now-last_control>=100000000ull){
            int physical=pointer_down;for(int i=0;i<512&&!physical;i++)physical=pressed[i]!=0;
            ctl_poll(physical);last_control=control_now;
        }
        LOCK;int draw=dirty;if(draw){SDL_UpdateTexture(tex,NULL,frame,width*4);dirty=0;}UNLOCK;
        if(draw){SDL_RenderClear(ren);SDL_RenderCopy(ren,tex,NULL,NULL);SDL_RenderPresent(ren);}
        uint64_t now=ns(CLOCK_MONOTONIC);if(now-last>=1000000000ull){sample();flush_effects();last=now;}
        if(now-last_paint_report>=5000000000ull){fprintf(stderr,"LAB_PAINT_WINDOW mono_ns=%llu\n%s\n",(unsigned long long)now,treo_vm_paint_sample_report());treo_vm_paint_sample_reset();last_paint_report=now;}
        if(trace_graph&&atomic_load_explicit(&jarbox_lab_trace_enabled,memory_order_relaxed)&&now-last_graph>=5000000000ull){if(!write_graph())unsupported("graph export");last_graph=now;}
        SDL_Delay(8);
    }
    ctl_close();pthread_join(th,NULL);sample();flush_effects();
    fprintf(stderr,"LAB_PAINT_WINDOW final=1 mono_ns=%llu\n%s\n",(unsigned long long)ns(CLOCK_MONOTONIC),treo_vm_paint_sample_report());
    fclose(trace);
    if(effect_file){fclose(effect_file);fprintf(stderr,"LAB_EFFECTS_LOST=%llu\n",(unsigned long long)effect_lost);}
    if(trace_graph&&!write_graph())unsupported("graph export");
    size_t nl=strlen(trace_path)+32;char *np=malloc(nl);
    if(np){snprintf(np,nl,"%s.network.csv",trace_path);FILE *nf=fopen(np,"w");if(nf){
        fputs("stage,count\n",nf);for(int i=0;i<32;i++)fprintf(nf,"%d,%llu\n",i,(unsigned long long)atomic_load(&net_stages[i]));fclose(nf);
    }free(np);}
    fprintf(stderr,"LAB_LOGIC mode=%d plans=%llu spans=%llu ops=%llu\n",logic_mode,
        (unsigned long long)atomic_load(&logic_plans),(unsigned long long)atomic_load(&logic_spans),
        (unsigned long long)atomic_load(&logic_ops));
    fprintf(stderr,"LAB_DISPATCH fixture=%d methods=%llu\n",jarbox_lab_dispatch_fixture,(unsigned long long)jarbox_desktop_direct_method_batches());
    fprintf(stderr,"LAB_EXIT rc=%d failed=%d frames=%llu input_overflow=%llu\n",rc,atomic_load(&failed),(unsigned long long)atomic_load(&frames),(unsigned long long)event_overflow);
    for(unsigned i=1;i<MAX_SURF;i++)if(surfaces[i].s)drop((s64)surfaces[i].id);
    SDL_DestroyTexture(tex);SDL_DestroyRenderer(ren);SDL_DestroyWindow(win);SDL_Quit();free(frame);
    return rc||atomic_load(&failed)?1:0;
}
