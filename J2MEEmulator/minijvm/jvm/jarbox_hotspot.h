#ifndef JARBOX_HOTSPOT_H
#define JARBOX_HOTSPOT_H
#include <stdint.h>
#include <stddef.h>
#include <string.h>
#include <stdio.h>

// Cooperative sampling, no pointers to VM metadata survive the checkpoint.
// Space-Saving: count is an upper bound, count-error a lower bound.
enum { JARBOX_HOT_ROWS=64, JARBOX_HOT_KEY=144, JARBOX_HOT_TOP=6, JARBOX_HOT_TEXT=1280 };
typedef struct {
    uint64_t count, error;
    uint32_t pc;
    unsigned scope;
    char key[JARBOX_HOT_KEY];
} JarBoxHotRow;
typedef struct {
    unsigned lock;
    uint64_t accepted, busy, invalid;
    JarBoxHotRow row[JARBOX_HOT_ROWS];
} JarBoxHotspot;
static inline int jarbox_hot_try(JarBoxHotspot *h) {
    unsigned expected=0;
    return __atomic_compare_exchange_n(&h->lock,&expected,1,0,__ATOMIC_ACQUIRE,__ATOMIC_RELAXED);
}
static inline void jarbox_hot_unlock(JarBoxHotspot *h) {
    __atomic_store_n(&h->lock,0,__ATOMIC_RELEASE);
}
// One opportunity per 256 checkpoints, at most 100 samples per thread-CPU second.
// No catch-up bursts after a long native call or paused thread.
static inline int jarbox_hot_due(uint64_t now,uint64_t *next) {
    if (!now || (*next && now<*next)) return 0;
    int due=*next!=0;
    *next=now>UINT64_MAX-10000000 ? UINT64_MAX : now+10000000;
    return due;
}
// Escape delimiters, non-ASCII and control bytes. Reject overlong identities
// instead of merging truncated names. Input strings are live metadata only.
static inline int jarbox_hot_key(char out[JARBOX_HOT_KEY],const char *cls,const char *method,const char *desc) {
    const char *parts[]={cls,method,desc}; const char hex[]="0123456789ABCDEF"; size_t n=0;
    for(unsigned p=0;p<3;p++) {
        if (!parts[p] || !*parts[p]) return 0;
        if (p) { if(n+1>=JARBOX_HOT_KEY)return 0;out[n++]='~'; }
        for(const unsigned char *s=(const unsigned char *)parts[p];*s;s++) {
            unsigned c=*s;
            int safe=(c>='a'&&c<='z')||(c>='A'&&c<='Z')||(c>='0'&&c<='9')||strchr("._/$()-",(int)c)!=NULL;
            size_t len=safe?1:3;
            if(n+len>=JARBOX_HOT_KEY)return 0;
            if(safe)out[n++]=(char)c;
            else {out[n++]='%';out[n++]=hex[c>>4];out[n++]=hex[c&15];}
        }
    }
    out[n]=0;return 1;
}
static inline void jarbox_hot_note(JarBoxHotspot *h,const char *cls,const char *method,const char *desc,unsigned scope,uint32_t pc) {
    char key[JARBOX_HOT_KEY];
    if (!jarbox_hot_key(key,cls,method,desc)) {__atomic_fetch_add(&h->invalid,1,__ATOMIC_RELAXED);return;}
    if (!jarbox_hot_try(h)) {__atomic_fetch_add(&h->busy,1,__ATOMIC_RELAXED);return;}
    unsigned victim=0;
    for(unsigned i=0;i<JARBOX_HOT_ROWS;i++) {
        JarBoxHotRow *r=&h->row[i];
        if(r->count && r->scope==scope && !strcmp(r->key,key)) {victim=i;goto found;}
        if(r->count<h->row[victim].count)victim=i;
    }
    h->row[victim].error=h->row[victim].count;
    h->row[victim].scope=scope;
    strcpy(h->row[victim].key,key);
found:
    ++h->row[victim].count;
    h->row[victim].pc=pc;
    ++h->accepted;
    jarbox_hot_unlock(h);
}
// Output is bounded, delimiter-safe and only contains code identities.
// No wait: a busy report is explicitly invalid, never a zero sample window.
static inline int jarbox_hot_report(JarBoxHotspot *h,uint64_t *accepted,char out[JARBOX_HOT_TEXT]) {
    out[0]=0;*accepted=0;
    if(!jarbox_hot_try(h))return 0;
    JarBoxHotRow top[JARBOX_HOT_TOP]={0};
    *accepted=h->accepted;
    for(unsigned i=0;i<JARBOX_HOT_ROWS;i++) {
        const JarBoxHotRow *r=&h->row[i];
        for(unsigned j=0;j<JARBOX_HOT_TOP;j++) {
            if(r->count<=top[j].count)continue;
            for(unsigned k=JARBOX_HOT_TOP-1;k>j;k--)top[k]=top[k-1];
            top[j]=*r;break;
        }
    }
    jarbox_hot_unlock(h);
    size_t n=0;
    for(unsigned i=0;i<JARBOX_HOT_TOP && top[i].count;i++) {
        JarBoxHotRow *r=&top[i];
        int len=snprintf(out+n,JARBOX_HOT_TEXT-n,"%s%llu:%llu:%u:%u:%s",i?"|":"",(unsigned long long)r->count,(unsigned long long)r->error,(unsigned)r->pc,r->scope,r->key);
        if(len<0 || (size_t)len>=JARBOX_HOT_TEXT-n){out[0]=0;*accepted=0;return 0;}
        n+=(size_t)len;
    }
    return 1;
}
#endif
