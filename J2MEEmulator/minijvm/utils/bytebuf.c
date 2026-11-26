//
// Created by gust on 2017/12/16.
//
#include "memory.h"
#include "bytebuf.h"
#include <string.h>

ByteBuf *bytebuf_create(u32 size) {
    if (!size) size = 256;
    ByteBuf *bf = jvm_calloc(sizeof(ByteBuf));
    if (!bf) return NULL;
    bf->buf = jvm_calloc(size);
    if (!bf->buf) { jvm_free(bf); return NULL; }
    bf->_alloc_size = size;
    return bf;
}

void bytebuf_destroy(ByteBuf *bf) {
    if (bf) {
        jvm_free(bf->buf);
        jvm_free(bf);
    }
}

static int bytebuf_valid(const ByteBuf *bf) {
    return bf && bf->buf && bf->rp <= bf->wp && bf->wp <= bf->_alloc_size;
}

u32 bytebuf_available(ByteBuf *bf) {
    return bytebuf_valid(bf) ? bf->wp - bf->rp : 0;
}

static int bytebuf_reserve_write(ByteBuf *bf, u32 bytes) {
    if (!bytebuf_valid(bf) || bytes > UINT32_MAX - bf->wp) return 0;
    const u32 needed = bf->wp + bytes;
    if (needed > bf->_alloc_size) {
        u32 grown = bf->_alloc_size <= UINT32_MAX / 2 ? bf->_alloc_size * 2 : UINT32_MAX;
        bytebuf_expand(bf, grown > needed ? grown : needed);
    }
    return needed <= bf->_alloc_size;
}


s32 bytebuf_write(ByteBuf *bf, s32 v) {
    if (!bytebuf_reserve_write(bf, sizeof(c8))) return -1;

    bf->buf[bf->wp++] = v;
    return 1;
}

s32 bytebuf_write_byte(ByteBuf *bf, c8 v) {
    return bytebuf_write(bf, v);
}

s32 bytebuf_write_short(ByteBuf *bf, s16 v) {
    if (!bytebuf_reserve_write(bf, sizeof(s16))) return -1;
    bf->buf[bf->wp++] = (u8) (v >> 8);
    bf->buf[bf->wp++] = (u8) (v);
    return 2;
}

s32 bytebuf_write_int(ByteBuf *bf, s32 v) {
    if (!bytebuf_reserve_write(bf, sizeof(s32))) return -1;
    bf->buf[bf->wp++] = (u8) (v >> 24);
    bf->buf[bf->wp++] = (u8) (v >> 16);
    bf->buf[bf->wp++] = (u8) (v >> 8);
    bf->buf[bf->wp++] = (u8) (v);
    return 4;
}

s32 bytebuf_write_long(ByteBuf *bf, s64 v) {
    if (!bytebuf_reserve_write(bf, sizeof(s64))) return -1;
    bf->buf[bf->wp++] = (u8) (v >> 56);
    bf->buf[bf->wp++] = (u8) (v >> 48);
    bf->buf[bf->wp++] = (u8) (v >> 40);
    bf->buf[bf->wp++] = (u8) (v >> 32);
    bf->buf[bf->wp++] = (u8) (v >> 24);
    bf->buf[bf->wp++] = (u8) (v >> 16);
    bf->buf[bf->wp++] = (u8) (v >> 8);
    bf->buf[bf->wp++] = (u8) (v);
    return 8;
}


s32 bytebuf_write_batch(ByteBuf *bf, c8 *data, s32 size) {
    if (size < 0 || !bytebuf_valid(bf) || (size && !data)) return -1;
    if (!size) return 0;
    // A batch may refer to this buffer; preserve the source across growth.
    uintptr_t base = (uintptr_t)bf->buf, src = (uintptr_t)data;
    const int internal = src >= base && src - base < bf->_alloc_size;
    u32 offset = internal ? (u32)(src - base) : 0;
    if (internal && (offset > bf->wp || (u32)size > bf->wp - offset)) return -1;
    if (!bytebuf_reserve_write(bf, (u32)size)) return -1;
    if (internal) data = bf->buf + offset;
    memmove(&bf->buf[bf->wp], data, size);
    bf->wp += (u32)size;
    return size;
}

//-----------------------------------------------------------------------------------
s32 bytebuf_hasmore(ByteBuf *bf, u32 size) {
    return bytebuf_valid(bf) && size <= bf->wp - bf->rp;
}

s32 bytebuf_read(ByteBuf *bf) {
    if (!bytebuf_hasmore(bf, 1)) {
        return -1;
    }
    s32 i = (u8) bf->buf[bf->rp++];
    return i;
}

c8 bytebuf_read_byte(ByteBuf *bf) {
    return (c8) bytebuf_read(bf);
}

s16 bytebuf_read_short(ByteBuf *bf) {
    if (!bytebuf_hasmore(bf, 2)) {
        return -1;
    }
    s16 i = (u8) bf->buf[bf->rp++];
    i <<= 8;
    i |= (u8) bf->buf[bf->rp++];
    return i;
}

s32 bytebuf_read_int(ByteBuf *bf) {
    if (!bytebuf_hasmore(bf, 4)) {
        return -1;
    }
    u32 i = (u8) bf->buf[bf->rp++];
    i <<= 8;
    i |= (u8) bf->buf[bf->rp++];
    i <<= 8;
    i |= (u8) bf->buf[bf->rp++];
    i <<= 8;
    i |= (u8) bf->buf[bf->rp++];
    return i;
}

s64 bytebuf_read_long(ByteBuf *bf) {
    if (!bytebuf_hasmore(bf, 8)) {
        return -1;
    }

    u64 i = (u8) bf->buf[bf->rp++];
    i <<= 8;
    i |= (u8) bf->buf[bf->rp++];
    i <<= 8;
    i |= (u8) bf->buf[bf->rp++];
    i <<= 8;
    i |= (u8) bf->buf[bf->rp++];
    i <<= 8;
    i |= (u8) bf->buf[bf->rp++];
    i <<= 8;
    i |= (u8) bf->buf[bf->rp++];
    i <<= 8;
    i |= (u8) bf->buf[bf->rp++];
    i <<= 8;
    i |= (u8) bf->buf[bf->rp++];
    return i;
}


s32 bytebuf_read_batch(ByteBuf *bf, c8 *data, s32 size) {
    if (size <= 0 || !data || !bytebuf_valid(bf)) return -1;
    u32 available = bytebuf_available(bf);
    s32 len = (u32)size < available ? size : (s32)available;
    if (!len) return -1;
    memmove(data, &bf->buf[bf->rp], len);
    bf->rp += len;
    return len;
}


s32 bytebuf_read_from(ByteBuf *bf, ByteBuf *src, s32 size) {
    if (size <= 0) {
        return size;
    }
    if (!bytebuf_valid(bf) || !bytebuf_valid(src)) return -1;
    u32 available = bytebuf_available(src);
    s32 len = (u32)size < available ? size : (s32)available;
    if (bytebuf_write_batch(bf, &src->buf[src->rp], len) != len) return -1;
    src->rp += (u32)len;
    return len;
}


s32 bytebuf_write_to(ByteBuf *bf, ByteBuf *dst, s32 size) {
    if (size <= 0) {
        return size;
    }
    return bytebuf_read_from(dst, bf, size);
}
//------------------------------------private ---------------------------------------


void bytebuf_expand(ByteBuf *bf, u32 size) {
    // Growth only; never copy wp bytes into a smaller allocation.
    if (!bytebuf_valid(bf) || size <= bf->_alloc_size) return;

    /* Calculate actual data size to copy */
    u32 data_size = bf->wp;

    void *p = jvm_malloc(size);
    if (p) {
        /* Copy only the actual data that is in use */
        if (data_size > 0) {
            memmove(p, bf->buf, data_size);
        }

        /* Free old memory */
        jvm_free(bf->buf);

        bf->buf = p;
        bf->_alloc_size = size;
    }
}


s32 bytebuf_chkread(ByteBuf *bf, u32 pos) {
    if (!bytebuf_valid(bf) || pos > bf->wp) {
        return 0;
    }
    return 1;
}
