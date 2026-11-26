#include "jarbox_canvas_phase.h"
#include <assert.h>
#include <stdio.h>
static void points(JarBoxCanvasPhaseScope *s,uint64_t owner) {
    jarbox_canvas_phase_point(s,owner,1,20);jarbox_canvas_phase_point(s,owner,2,40);
}
int main(void) {
    JarBoxCanvasPhaseScope s={0};JarBoxCanvasPhaseStats a={0},b={0};JarBoxCanvasPhaseTotals t;
    for(unsigned i=0;i<100000;i++) {
        jarbox_canvas_phase_begin(&s,1,1,10);points(&s,1);
        assert(jarbox_canvas_phase_end(&s,&a,1,1,50));
    }
    assert(jarbox_canvas_phase_snapshot(&a,&t)&&t.frames==100000&&t.pre_ns==1000000&&t.paint_ns==2000000&&t.post_ns==1000000);
    jarbox_canvas_phase_begin(&s,1,1,10);points(&s,1);jarbox_canvas_phase_begin(&s,1,1,15);
    assert(!jarbox_canvas_phase_end(&s,&a,1,1,50));assert(!jarbox_canvas_phase_end(&s,&a,1,1,50)&&a.invalid==1);
    jarbox_canvas_phase_begin(&s,1,1,10);jarbox_canvas_phase_point(&s,1,2,40);
    assert(!jarbox_canvas_phase_end(&s,&a,1,1,50)&&a.invalid==2);
    jarbox_canvas_phase_begin(&s,1,1,10);points(&s,1);
    assert(!jarbox_canvas_phase_end(&s,&a,1,0,50)&&a.invalid==3);
    jarbox_canvas_phase_begin(&s,1,1,10);points(&s,1);
    assert(!jarbox_canvas_phase_end(&s,&a,1,1,30)&&a.invalid==4);
    jarbox_canvas_phase_begin(&s,1,1,10);points(&s,1);
    jarbox_canvas_phase_begin(&s,2,1,10);points(&s,2);
    assert(jarbox_canvas_phase_end(&s,&b,2,1,50)&&b.totals.frames==1);
    jarbox_canvas_phase_begin(&s,1,0,0);points(&s,1);
    assert(!jarbox_canvas_phase_end(&s,&a,1,1,50)&&a.invalid==4);
    jarbox_canvas_phase_begin(&s,1,1,10);points(&s,1);assert(jarbox_canvas_phase_try(&a));
    assert(!jarbox_canvas_phase_end(&s,&a,1,1,50)&&a.busy==1);
    assert(!jarbox_canvas_phase_snapshot(&a,&t)&&!t.frames);jarbox_canvas_phase_unlock(&a);
    assert(jarbox_canvas_phase_snapshot(&a,&t)&&t.frames==100000);
    jarbox_canvas_phase_begin(&s,1,1,10);points(&s,1);
    assert(!jarbox_canvas_phase_end(&s,&b,2,1,50)&&b.totals.frames==1);
    puts("PASS 100000 Canvas timing scopes, nested/malformed/mode/owner/busy rejection");
}
