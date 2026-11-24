"""Extract the production iOS clock path; use Linux's real monotonic clock."""
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

SOURCE = Path(__file__).resolve().parents[2] / "J2MEEmulator/minijvm/jvm/jvm_util.c"
PRE = r'''
#define _POSIX_C_SOURCE 200809L
#include <assert.h>
#include <stdint.h>
#include <stdatomic.h>
#include <pthread.h>
#include <stdio.h>
#include <time.h>
typedef long long s64;
#define NANO_2_SEC_SCALE 1000000000LL
#define __JVM_OS_IOS__ 1
'''
MAIN = r'''
static atomic_int ready, go;
static void *work(void *p) {
    (void)p; atomic_fetch_add(&ready,1); while(!atomic_load(&go)) {}
    s64 last=nanoTime();
    for(int i=0;i<100000;i++){s64 n=nanoTime(); assert(n>=last);last=n;}
    return NULL;
}
int main(void){
    for(int i=0;i<20;i++){
        atomic_store(&nano_sec_start_at,0);atomic_store(&ready,0);atomic_store(&go,0);
        pthread_t t[4];for(int j=0;j<4;j++)assert(!pthread_create(&t[j],0,work,0));
        while(atomic_load(&ready)!=4){} atomic_store(&go,1);
        for(int j=0;j<4;j++)assert(!pthread_join(t[j],0));
        s64 o=atomic_load(&nano_sec_start_at);assert(o>0);nanoTime();assert(atomic_load(&nano_sec_start_at)==o);
    }
    puts("PASS: 20 concurrent first-use rounds; 8000000 monotonic reads");
}
'''
class GameClockTest(unittest.TestCase):
    def test_parallel_first_use(self):
        cc = shutil.which(os.environ.get("CC", "cc"))
        if not cc:
            self.skipTest("C compiler unavailable")
        src = SOURCE.read_text()
        origin = next(line for line in src.splitlines() if line.startswith("static _Atomic s64 nano_sec_start_at"))
        a = src.index("s64 nanoTime() {")
        b = src.index("\n}", a) + 2
        flags = ["-std=c11", "-O1", "-Wall", "-Wextra", "-Werror", "-pthread"]
        if os.environ.get("JARBOX_CLOCK_SANITIZE") == "1":
            flags += ["-g", "-fsanitize=address,undefined"]
        with tempfile.TemporaryDirectory() as td:
            p, exe = Path(td) / "clock.c", Path(td) / "clock"
            p.write_text(PRE + origin + "\n" + src[a:b] + MAIN)
            subprocess.run([cc,*flags,str(p),"-o",str(exe)],check=True,timeout=30)
            r=subprocess.run([str(exe)],check=True,capture_output=True,text=True,timeout=30)
            self.assertIn("8000000 monotonic reads",r.stdout)
    def test_wall_clock_unchanged(self):
        source = SOURCE.read_text()
        body = source.split("s64 currentTimeMillis() {",1)[1].split("\n}",1)[0]
        self.assertIn("timespec_get(&tv, TIME_UTC)",body)
        nano = source.split("s64 nanoTime() {",1)[1].split("\n}",1)[0]
        self.assertIn("clock_gettime(CLOCK_MONOTONIC, &tv)",nano)
        self.assertIn("atomic_compare_exchange_strong_explicit(&nano_sec_start_at",nano)
if __name__=="__main__":
    unittest.main()
