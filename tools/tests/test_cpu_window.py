"""Boundary CPU accounting: deterministic host window fixture."""
from pathlib import Path
import subprocess
import shutil
import tempfile
import unittest
ROOT=Path(__file__).resolve().parents[2]
JVM=ROOT/"J2MEEmulator/minijvm/jvm"
C=r"""
#include "jarbox_cpu_window.h"
#include <stdio.h>
#define CHECK(x) do {if(!(x)){fprintf(stderr,"line %d\n",__LINE__);return 1;}} while(0)
static JarBoxCpuPoint point(uint64_t n){
    JarBoxCpuPoint p={0};
    p.wall_ns=n*1000;p.process_ns=n*200;p.runner_ns=n*20;
    p.java_ns=n*100;p.gc_ns=n*30;p.gc_cycles=n;p.requests=n*10;
    p.skips=n*8;p.process_ok=1;return p;
}
int main(void){
    JarBoxCpuHistory a={0},b={0};
    jarbox_cpu_history_transition(&a,0,point(1));
    jarbox_cpu_history_transition(&a,8,point(11));
    jarbox_cpu_history_transition(&a,8,point(21));
    jarbox_cpu_history_transition(&b,0,point(25));
    jarbox_cpu_history_transition(&a,0,point(31));
    JarBoxCpuSnapshot s=jarbox_cpu_history_snapshot(&a,point(33));
    CHECK(s.last_visible.valid && s.last_visible.mode==0 && s.last_visible.elapsed_ns==10000);
    CHECK(s.last_treo.mode==8 && s.last_treo.elapsed_ns==20000);
    CHECK(s.last_treo.process_ns==4000 && s.last_treo.runner_ns==400);
    CHECK(s.last_treo.java_ns==2000 && s.last_treo.gc_ns==600);
    CHECK(s.last_treo.gc_cycles==20 && s.last_treo.requests==200 && s.last_treo.skips==160);
    CHECK(s.current.elapsed_ns==2000 && s.current.threads_ok && s.current.process_ok);
    CHECK(!b.last_treo.valid && !b.last_visible.valid);
    jarbox_cpu_history_transition(&a,1,point(41));
    jarbox_cpu_history_transition(&a,8,point(51));
    CHECK(a.last_treo.mode==1 && a.last_treo.elapsed_ns==10000);
    JarBoxCpuPoint x=point(61);x.errors=1;
    s=jarbox_cpu_history_snapshot(&a,x);
    CHECK(s.current.valid && !s.current.threads_ok && s.current.sample_errors==1 && s.current.process_ok);
    CHECK(!jarbox_cpu_window(point(10),point(9),0).valid);
    x=point(71);x.process_ok=0;
    CHECK(!jarbox_cpu_window(point(61),x,0).process_ok);
    x=point(71);x.java_ns=0;
    CHECK(!jarbox_cpu_window(point(61),x,0).threads_ok);
    puts("CPU window: PASS");return 0;
}
"""
class CpuWindowTest(unittest.TestCase):
    def test_boundary_math(self):
        cc=shutil.which("cc")
        if not cc:self.skipTest("host compiler unavailable")
        with tempfile.TemporaryDirectory() as td:
            p,exe=Path(td)/"cpu.c",Path(td)/"cpu"
            p.write_text(C)
            subprocess.run([cc,"-std=c11","-Wall","-Wextra","-Werror","-I",str(JVM),str(p),"-o",str(exe)],check=True,timeout=30)
            subprocess.run([str(exe)],check=True,timeout=10)
    def test_lifetime_and_on_demand_wiring(self):
        bridge=(ROOT/"J2MEEmulator/NativeBridge/jvm_bridge.c").read_text()
        self.assertIn("t->port=mach_thread_self()",bridge)
        self.assertIn("mach_port_deallocate(mach_task_self(),t->port)",bridge)
        self.assertIn("s->cpu_retired_ns[t->kind]+=t->latest_ns-t->baseline_ns",bridge)
        self.assertIn("jvm_bridge_visit_running_vm_for_token(token,bridge_cpu_snapshot,out)",bridge)
        self.assertIn("getrusage(RUSAGE_SELF,&ru)",bridge)
        u=(JVM/"jvm_util.c").read_text().split("s32 jthread_run(void *para) {",1)[1].split("s32 jthread_run_finalize",1)[0]
        self.assertLess(u.index("jvm_bridge_cpu_worker_begin(held_session,JARBOX_CPU_JAVA)"),u.index("ret = execute_method_impl(method, runtime)"))
        self.assertLess(u.index("jvm_bridge_cpu_worker_end(held_session)"),u.index("// No Runtime or JavaThreadInfo dereference"))
        g=(JVM/"garbage.c").read_text().split("s32 _gc_thread_run(void *para) {",1)[1].split("static void gc_process_deferred_objects",1)[0]
        self.assertLess(g.index("jvm_bridge_cpu_worker_end(jvm->session)"),g.index("GARBAGE_THREAD_DEAD, __ATOMIC_RELEASE"))
        r=(ROOT/"J2MEEmulator/NativeBridge/j2me_render.m").read_text()
        self.assertIn("jvm_bridge_cpu_mode_changed(vm->session);",r)
        sw=(ROOT/"J2MEEmulator/UI/GameViewController.swift").read_text()
        self.assertEqual(sw.count("jvm_bridge_cpu_snapshot_for_token("),1)
        self.assertIn('cpuWindow("last_treo", cpu.last_treo)',sw)
if __name__=="__main__":unittest.main()
