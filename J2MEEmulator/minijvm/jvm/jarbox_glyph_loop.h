#ifndef JARBOX_GLYPH_LOOP_H
#define JARBOX_GLYPH_LOOP_H
#include <stdint.h>
#include <string.h>

/* Whole-loop preflight for a closed bitmap-font draw. Only native UTF-16
 * lookup and fault-domain checks remain; no glyph coordinate or width math.
 * A refusal is side-effect-free and must resume at the original loop PC. */
enum { JBG_MAX_TEXT=512,JBG_MAX_ALPHABET=512 };
typedef struct {const unsigned char *data; unsigned count;} JbgText;
typedef void *(*JbgRow)(void *,unsigned);
static inline uint16_t jbg_char(JbgText s,unsigned i){
    uint16_t c;memcpy(&c,s.data+2u*i,sizeof(c));return c;
}
static inline unsigned jbg_index(JbgText alphabet,uint16_t c){
    for(unsigned i=0;i<alphabet.count;++i)if(jbg_char(alphabet,i)==c)return i;
    return 0; /* Nick's exact missing-character rule */
}
static inline int jbg_loop_preflight(JbgText text,JbgText alphabet,JbgRow row,void *ctx,void **last){
    if(!last||!row||!text.count||text.count>JBG_MAX_TEXT||!text.data||
       alphabet.count>JBG_MAX_ALPHABET||(alphabet.count&&!alphabet.data))return 0;
    /* On a long string prove the entire fault domain, so no per-glyph
     * lookup is necessary except the last row for reference-lane replay.
     * A malformed unused row conservatively refuses the whole contraction. */
    unsigned end=alphabet.count?alphabet.count:1;
    if(text.count>=4){
        for(unsigned i=0;i<end;++i)if(!row(ctx,i))return 0;
    }else{
        for(unsigned i=0;i<text.count;++i)
            if(!row(ctx,jbg_index(alphabet,jbg_char(text,i))))return 0;
    }
    void *v=row(ctx,jbg_index(alphabet,jbg_char(text,text.count-1)));
    if(!v)return 0;
    *last=v;return 1;
}
/* Exact final reference-lane writes of the two Nick glyph loops at PC49,
 * through the last completed drawRegion wrapper and width advance. Caller
 * must prove that the String calls and wrapper use the certified scratch
 * shape; slots 6..9 are never written as references. Integer lanes are dead
 * at the void return. No Java frame is entered or allocation performed. */
static inline void jbg_replay(StackEntry *sp,void *wrapper,void *font,void *row,
                              void *graphics,void *image){
    sp[0].rvalue=wrapper;sp[1].rvalue=row;sp[2].rvalue=font;
    sp[3].rvalue=row;sp[4].rvalue=row;sp[5].rvalue=row;
    sp[10].rvalue=graphics;sp[11].rvalue=image;
}
#endif
