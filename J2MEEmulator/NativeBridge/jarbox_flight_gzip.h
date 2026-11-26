#ifndef JARBOX_FLIGHT_GZIP_H
#define JARBOX_FLIGHT_GZIP_H
#include <stdint.h>
#include <stddef.h>
#include <string.h>
// RFC 1952 single member. Caller provides raw DEFLATE, CRC32 and size.
static inline void jarbox_flight_gzip_frame(uint8_t *out,const void *raw,size_t raw_size,uint32_t crc,uint32_t input_size) {
    const uint8_t header[10]={0x1f,0x8b,8,0,0,0,0,0,0,255};
    memcpy(out,header,sizeof(header));
    memcpy(out+10,raw,raw_size);
    for(unsigned j=0;j<4;j++) {
        out[10+raw_size+j]=(uint8_t)(crc>>(8*j));
        out[14+raw_size+j]=(uint8_t)(input_size>>(8*j));
    }
}
#endif
