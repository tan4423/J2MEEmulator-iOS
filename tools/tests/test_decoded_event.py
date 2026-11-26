"""Host regression for bounded decoded primitive plans and targeted long sleep.

Production headers are compiled verbatim. VM layout and waiter publication
are modeled for the sleep test; Linux uses POSIX fallback, macOS native wait.
"""
from pathlib import Path
import os
import shutil
import subprocess
import tempfile
import unittest

ROOT=Path(__file__).resolve().parents[2]
JVM=ROOT/"J2MEEmulator/minijvm/jvm"
HERE=Path(__file__).resolve().parent

class DecodedEventTest(unittest.TestCase):
    def test_host(self):
        cc=shutil.which(os.environ.get("CC","cc"))
        if not cc:self.skipTest("host C compiler unavailable")
        flags=["-std=c11","-O2","-Wall","-Wextra","-Werror","-pthread"]
        if os.environ.get("JARBOX_DECODED_EVENT_SANITIZE")=="1":
            flags+=["-O1","-g","-fsanitize=address,undefined","-fno-omit-frame-pointer"]
        with tempfile.TemporaryDirectory() as d:
            for name,marker in (("decoded_int_host.c","100000 decoded expression batches PASS"),
                                ("event_sleep_host.c","100 targeted wake batches and deadline PASS")):
                with self.subTest(name=name):
                    exe=Path(d)/"test"
                    subprocess.run([cc,*flags,"-I",str(JVM),str(HERE/name),"-o",str(exe)],check=True,timeout=30)
                    run=subprocess.run([str(exe)],capture_output=True,text=True,timeout=30)
                    self.assertEqual(run.returncode,0,run.stdout+run.stderr)
                    self.assertIn(marker,run.stdout)
    def test_wiring(self):
        c=(JVM/"class_load.c").read_text()
        block=c.split("ptr->converted_code = ca;",1)[1].split("_changeBytesOrder(ptr);",1)[0]
        self.assertIn("jarbox_decoded_int_build(",block)
        self.assertIn("ptr->is_static && !ptr->is_native && !ptr->is_sync",block)
        self.assertIn("ptr->para_slots == ca->max_locals",block)
        i=(JVM/"interpreter.c").read_text()
        fast=i.split("CodeAttribute *decoded = method->converted_code;",1)[1].split("#endif",1)[0]
        for guard in ("CLASS_STATUS_CLINITED","!pruntime->jvm->jdwp_enable","!method->breakpoint",
                      "!pruntime->thrd_info->is_stop","!pruntime->thrd_info->suspend_count",
                      "!treo_game_jit_enabled_fast()","decoded->max_stack <= caller->max_size - used",
                      "caller->sp = args;","push_int(caller, result);"):
            self.assertIn(guard,fast)
        u=(JVM/"jvm_util.c").read_text()
        for signature in ("void thread_stop_all(","s32 jthread_interrupt("):
            self.assertIn("jarbox_waiter_signal(info->sleep_waiter)",u.split(signature,1)[1].split("\n}",1)[0])
        wake=u.split("s32 jthread_wakeup(",1)[1].split("\n}",1)[0]
        self.assertNotIn("sleep_waiter",wake)
        sleep=u.split("s32 jthread_sleep(",1)[1].split("\n}",1)[0]
        self.assertIn("ms >= PERIOD && ms <= INT32_MAX",sleep)
        self.assertIn("jthread_block_exit(runtime)",sleep)
        self.assertIn("check_throw_interruptexception(runtime)",sleep)

if __name__=="__main__":unittest.main()
