#ifndef JARBOX_DECODED_INT_H
#define JARBOX_DECODED_INT_H
#include <stdint.h>
#include <string.h>

/* A validated, pointer-free packed plan for straight-line static int leaves.
 * Five-bit normalized operations, optional 16-bit immediate, zero terminator.
 * No calls, heap access, branches, exceptions, or Java frame layout changes. */
enum { JB_DI_LOAD0=1, JB_DI_CONST_M1=5, JB_DI_IMM16=12, JB_DI_NEG=13,
       JB_DI_ADD=14, JB_DI_SUB, JB_DI_MUL, JB_DI_AND, JB_DI_OR, JB_DI_XOR,
       JB_DI_SHL, JB_DI_SHR, JB_DI_USHR };
#define JB_DI_STACK 8
static inline int jarbox_di_append(uint64_t *plan,unsigned *used,unsigned v,unsigned width) {
    if (*used+width>59) return 0; // leave a zero terminator
    *plan |= (uint64_t)v << *used;
    *used += width;
    return 1;
}
static inline uint64_t jarbox_decoded_int_build(const uint8_t *code,int len,
        const char *desc,int locals,int max_stack,int handlers) {
    if (!code || !desc || len<2 || len>32 || handlers || locals<0 || locals>4 ||
        max_stack<1 || max_stack>JB_DI_STACK || *desc++!='(') return 0;
    for(int n=0;n<locals;++n) if (*desc++!='I') return 0;
    if (strcmp(desc,")I")) return 0;
    uint64_t plan=0;
    unsigned used=0;
    int depth=0;
    for(int pc=0;pc<len;) {
        unsigned op=code[pc++], tag=0, imm=0;
        if(op==0xac) return pc==len && depth==1 ? plan : 0;
        if(op>=0x1a && op<=0x1d) {
            unsigned index=op-0x1a;
            if(index>=(unsigned)locals) return 0;
            tag=JB_DI_LOAD0+index; ++depth;
        } else if(op==0x15) {
            if(pc>=len || code[pc]>=(unsigned)locals) return 0;
            tag=JB_DI_LOAD0+code[pc++]; ++depth;
        } else if(op>=2 && op<=8) {
            tag=JB_DI_CONST_M1+op-2; ++depth;
        } else if(op==0x10 || op==0x11) {
            if(len-pc<(op==0x10?1:2)) return 0;
            imm=code[pc++];
            if(op==0x10) { if(imm&128u) imm|=0xff00u; }
            else imm=(imm<<8)|code[pc++];
            tag=JB_DI_IMM16; ++depth;
        } else if(op==0x74) {
            if(depth<1) return 0;
            tag=JB_DI_NEG;
        } else {
            if(depth<2) return 0;
            switch(op) {
                case 0x60:tag=JB_DI_ADD;break; case 0x64:tag=JB_DI_SUB;break;
                case 0x68:tag=JB_DI_MUL;break; case 0x7e:tag=JB_DI_AND;break;
                case 0x80:tag=JB_DI_OR;break; case 0x82:tag=JB_DI_XOR;break;
                case 0x78:tag=JB_DI_SHL;break; case 0x7a:tag=JB_DI_SHR;break;
                case 0x7c:tag=JB_DI_USHR;break; default:return 0;
            }
            --depth;
        }
        if(depth>max_stack || !jarbox_di_append(&plan,&used,tag,5)) return 0;
        if(tag==JB_DI_IMM16 && !jarbox_di_append(&plan,&used,imm,16)) return 0;
    }
    return 0;
}
/* Called only with a successful build result. Scratch slots contain bits,
 * never references; all Java arithmetic uses defined unsigned operations. */
static inline int32_t jarbox_decoded_int_eval(uint64_t plan,const uint32_t args[4]) {
    uint32_t stack[JB_DI_STACK]; unsigned depth=0;
    while(plan) {
        unsigned tag=(unsigned)(plan&31u);plan>>=5;
        if(tag>=JB_DI_LOAD0 && tag<JB_DI_CONST_M1) stack[depth++]=args[tag-JB_DI_LOAD0];
        else if(tag>=JB_DI_CONST_M1 && tag<JB_DI_IMM16) stack[depth++]=(uint32_t)(tag-JB_DI_CONST_M1)-1u;
        else if(tag==JB_DI_IMM16) {
            uint32_t x=(uint32_t)(plan&65535u);plan>>=16;
            stack[depth++]=(x&32768u)?x|0xffff0000u:x;
        } else if(tag==JB_DI_NEG) stack[depth-1]=0u-stack[depth-1];
        else {
            uint32_t b=stack[--depth],a=stack[depth-1],v=0;unsigned n=b&31u;
            switch(tag) {
                case JB_DI_ADD:v=a+b;break; case JB_DI_SUB:v=a-b;break;
                case JB_DI_MUL:v=a*b;break; case JB_DI_AND:v=a&b;break;
                case JB_DI_OR:v=a|b;break; case JB_DI_XOR:v=a^b;break;
                case JB_DI_SHL:v=a<<n;break; case JB_DI_USHR:v=a>>n;break;
                case JB_DI_SHR:v=(a>>n)|((a&0x80000000u)&&n?(UINT32_MAX<<(32-n)):0u);break;
            }
            stack[depth-1]=v;
        }
    }
    int32_t result;memcpy(&result,stack,sizeof(result));return result;
}
#endif
