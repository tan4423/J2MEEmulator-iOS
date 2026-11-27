#ifndef JARBOX_NICK_MAP_EFFECT_H
#define JARBOX_NICK_MAP_EFFECT_H
#include <stdint.h>
#include <stddef.h>
#include <string.h>
/* Exact Nick t5 k1 effect projection, offline until linked-runtime and
 * original-PC/GC/scope gates exist. Not an authorization to omit paint.
 * Use signed Java arithmetic without C signed overflow. All inputs belong
 * to one immutable oracle snapshot; never cache live VM arrays here. */
typedef struct {
    int32_t x0,x1,y0,y1,stride,kind,scale,camera_x,center;
    const uint16_t *tiles; size_t tile_count;
    const int32_t *flags; size_t flag_count;
} JnmInput;
typedef struct {int32_t a,b,c,d;uint64_t writes,trace;} JnmResult;
static inline int32_t jnm_i32(uint32_t u){int32_t v;memcpy(&v,&u,4);return v;}
static inline int32_t jnm_add(int32_t a,int32_t b){return jnm_i32((uint32_t)a+(uint32_t)b);}
static inline int32_t jnm_sub(int32_t a,int32_t b){return jnm_i32((uint32_t)a-(uint32_t)b);}
static inline int32_t jnm_mul(int32_t a,int32_t b){return jnm_i32((uint32_t)a*(uint32_t)b);}
static inline int32_t jnm_div(int32_t a,int32_t b){return a==INT32_MIN&&b==-1?INT32_MIN:a/b;}
static inline int jnm_at(int32_t x,int32_t y,int32_t stride,size_t n,size_t *at){
    int32_t v=jnm_add(jnm_mul(y,stride),x);
    if(v<0||(uint32_t)v>=n)return 0;
    *at=(uint32_t)v;return 1;
}
static inline int jnm_char(const JnmInput *in,int32_t x,int32_t y,int32_t *v){
    size_t at;if(!in->tiles||!jnm_at(x,y,in->stride,in->tile_count,&at))return 0;
    *v=in->tiles[at];return 1;
}
static inline int jnm_flag(const JnmInput *in,int32_t x,int32_t y,int32_t *v){
    size_t at;if(!in->flags||!jnm_at(x,y,in->stride,in->flag_count,&at))return 0;
    *v=in->flags[at];return 1;
}
/* Classify a tile's surviving write path. Refuse on every invalid access,
 * including caught q3/m3 faults: original exception allocation is observable.
 * -1 refusal, 0 no game/static write, 1 preserve the 4 original writes. */
static inline int jnm_tile(const JnmInput *in,int32_t x,int32_t y){
    int32_t t,f,above,tmp;
    if(!jnm_char(in,x,y,&t)||!jnm_flag(in,x,y,&f))return -1;
    --t;
    if(f&256)return 0;
    if(in->kind==4&&(f&64)){
        if(!jnm_char(in,x,jnm_sub(y,1),&t))return -1;
        --t;
        switch(t){
            case 15:case 5:case 18:case 22:case 44:case 52:case 51:
            case 24:case 23:case 20:case 21:case 19:case 12:case 13:case -1:return 0;
            default:break;
        }
    }
    if(in->kind>=1&&in->kind<=3){
        if(f&32)return 0;
        if((in->kind==2&&(t==17||t==133))||(in->kind==3&&t==23))return 0;
        if(f&(64|2048)){
            if(!jnm_flag(in,x,jnm_sub(y,1),&above))return -1;
            if(above&32)return 0;
            if(above&4096){
                if(in->kind==2||in->kind==3){
                    if(!jnm_char(in,x,jnm_sub(y,1),&tmp))return -1;
                    if((in->kind==2&&(tmp==19||tmp==35))||(in->kind==3&&tmp==25))
                        if(!jnm_char(in,x,jnm_sub(y,2),&tmp))return -1;
                }
                return 0;
            }
        }
    }
    if(!(f&16))return 0;
    return in->scale?1:-1;
}
/* Trace the original putstatic order (a2,b2,d2,c2) with a portable uint64
 * hash. The offline oracle compares actual writes, not merely final fields. */
static inline void jnm_write(JnmResult *r,unsigned field,int32_t v){
    if(field==0)r->a=v;else if(field==1)r->b=v;else if(field==2)r->d=v;else r->c=v;
    r->trace=(r->trace*UINT64_C(1099511628211))^((uint64_t)field<<32)^(uint32_t)v;
    ++r->writes;
}
static inline int jnm_project(const JnmInput *in,const JnmResult *initial,JnmResult *out){
    if(!in||!initial||!out)return 0;
    int64_t w=(int64_t)in->x1-in->x0,h=(int64_t)in->y1-in->y0;
    if(w<=0||h<=0){*out=*initial;return 1;}
    if(w>4096||h>4096||w*h>16384||in->scale < -128||in->scale>127)return 0;
    JnmResult r=*initial;
    for(int32_t x=in->x0;x<in->x1;++x)for(int32_t y=in->y0;y<in->y1;++y){
        int mode=jnm_tile(in,x,y);
        if(mode<0)return 0;
        if(mode){
            int32_t a=jnm_sub(jnm_mul(x,in->scale),in->camera_x);
            int32_t b=jnm_sub(a,in->center);
            int32_t d=jnm_div(jnm_mul(jnm_sub(in->scale,2),b),in->scale);
            int32_t c=jnm_add(d,in->center);
            jnm_write(&r,0,a);jnm_write(&r,1,b);jnm_write(&r,2,d);jnm_write(&r,3,c);
        }
    }
    *out=r;return 1;
}
#endif
