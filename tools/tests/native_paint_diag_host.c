#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <zlib.h>
#include "jarbox_native_paint_diag.h"
#include "jarbox_flight_gzip.h"
int main(void) {
    unsigned positions=0;
    for(uint64_t b=0;b<100000;b++) {
        int count=0;
        for(unsigned n=0;n<32;n++) if(jarbox_native_paint_selected(b*32+n)){count++;positions|=1u<<n;}
        assert(count==1);
    }
    assert(positions==UINT32_MAX);
    assert(!jarbox_native_paint_pixels(-1,100));
    assert(jarbox_native_paint_pixels(INT32_MAX,INT32_MAX)==(uint64_t)INT32_MAX*INT32_MAX);
    assert(jarbox_native_paint_add(UINT64_MAX-1,3)==UINT64_MAX);
    assert(jarbox_native_paint_valid(100,10,20,70));
    assert(!jarbox_native_paint_valid(100,10,20,71));
    assert(!jarbox_native_paint_valid(UINT64_MAX,UINT64_MAX,1,0));
    for(unsigned n=0;n<1000;n++) {
        unsigned char input[1024],raw[2048],out[2066],decoded[1024];
        for(unsigned j=0;j<sizeof(input);j++) input[j]=(unsigned char)(j*n+j/9);
        z_stream s={0};
        assert(deflateInit2(&s,6,Z_DEFLATED,-15,8,Z_DEFAULT_STRATEGY)==Z_OK);
        s.next_in=input;s.avail_in=sizeof(input);s.next_out=raw;s.avail_out=sizeof(raw);
        assert(deflate(&s,Z_FINISH)==Z_STREAM_END);
        size_t raw_size=s.total_out;assert(deflateEnd(&s)==Z_OK);
        jarbox_flight_gzip_frame(out,raw,raw_size,(uint32_t)crc32(0,input,sizeof(input)),sizeof(input));
        z_stream d={0};assert(inflateInit2(&d,31)==Z_OK);
        d.next_in=out;d.avail_in=(uInt)raw_size+18;d.next_out=decoded;d.avail_out=sizeof(decoded);
        assert(inflate(&d,Z_FINISH)==Z_STREAM_END && d.total_out==sizeof(input));
        assert(!memcmp(input,decoded,sizeof(input)));assert(inflateEnd(&d)==Z_OK);
    }
    puts("PASS 100000 selection blocks, bounds, 1000 gzip framing round trips (system zlib)");
}
