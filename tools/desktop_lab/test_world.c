#include <assert.h>
#include "jarbox_world_observer.h"
int main(void){
 uint64_t s=0;assert(jwo_map(s)==-1&&jwo_zone(s)==-1&&!jwo_epoch(s));
 s=jwo_update(s,0,37);assert(jwo_map(s)==37&&jwo_zone(s)==-1&&jwo_epoch(s)==1);
 s=jwo_update(s,1,27);assert(jwo_map(s)==37&&jwo_zone(s)==27&&jwo_epoch(s)==2);
 assert(jwo_update(s,0,37)==s&&jwo_update(s,1,27)==s);
 s=jwo_update(s,0,10);s=jwo_update(s,0,37);assert(jwo_epoch(s)==4);
 s=jwo_update(s,1,255);assert(jwo_zone(s)==255);
 s=jwo_update(s,0,65535);assert(jwo_map(s)==-1);
 return 0;
}
