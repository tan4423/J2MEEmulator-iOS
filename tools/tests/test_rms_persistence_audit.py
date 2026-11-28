"""Compile actual RMS Java sources and test independent stores and safe logs.

This host JDK test exercises the same sources patched into j2me_api.jar.
It does not prove simultaneous miniJVM isolation or iPhone execution.
"""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
RMS = ROOT / "j2me_api/src/javax/microedition/rms"

HARNESS = r"""
import java.io.File;
import java.nio.file.Files;
import javax.microedition.rms.RecordStore;
import javax.microedition.rms.RecordStoreException;

public class RmsSmoke {
    public static void main(String[] args) throws Exception {
        System.setProperty("app.save.root", args[0]);
        String mode = args[1];
        if ("write".equals(mode)) {
            RecordStore r = RecordStore.openRecordStore("settings", true);
            byte[] secret = args[2].getBytes("UTF-8");
            r.addRecord(secret, 0, secret.length);
            r.closeRecordStore();
            return;
        }
        if ("read".equals(mode)) {
            RecordStore r = RecordStore.openRecordStore("settings", false);
            byte[] actual = r.getRecord(1);
            if (!args[2].equals(new String(actual, "UTF-8")))
                throw new AssertionError("RMS data leaked or changed");
            r.closeRecordStore();
            return;
        }
        if ("reopen".equals(mode)) {
            for (int i = 0; i < 64; i++) {
                RecordStore r = RecordStore.openRecordStore("settings", false);
                byte[] actual = r.getRecord(1);
                if (!args[2].equals(new String(actual, "UTF-8")))
                    throw new AssertionError("RMS data changed during repeated reopen");
                r.closeRecordStore();
            }
            return;
        }
        if ("cache".equals(mode)) {
            RecordStore r = RecordStore.openRecordStore("settings", false);
            byte[] actual = r.getRecord(1);
            if (!args[2].equals(new String(actual, "UTF-8")))
                throw new AssertionError("cached RMS data changed");
            r.closeRecordStore();
            java.lang.reflect.Field managerField = RecordStore.class.getDeclaredField("recordStoreManager");
            managerField.setAccessible(true);
            Object manager = managerField.get(null);
            java.lang.reflect.Field cacheField = manager.getClass().getDeclaredField("closedStoreCache");
            cacheField.setAccessible(true);
            java.util.Map cache = (java.util.Map) cacheField.get(manager);
            if (cache.size() != 1) throw new AssertionError("closed store not cached");
            RecordStore again = RecordStore.openRecordStore("settings", false);
            if (again == r) throw new AssertionError("cache reused a closed RecordStore handle");
            boolean staleHandleStayedClosed = false;
            try {
                r.getRecord(1);
            } catch (RecordStoreException expected) {
                staleHandleStayedClosed = true;
            }
            if (!staleHandleStayedClosed) throw new AssertionError("stale closed handle became usable again");
            if (!args[2].equals(new String(again.getRecord(1), "UTF-8")))
                throw new AssertionError("cached reopen data mismatch");
            if (cache.size() != 0) throw new AssertionError("cache entry not claimed");
            again.closeRecordStore();
            if (cache.size() != 1) throw new AssertionError("closed store not returned to cache");
            RecordStore.deleteRecordStore("settings");
            if (cache.size() != 0) throw new AssertionError("deleted store remained cached");
            if (new File(args[0] + "/rms/settings.rsh").exists())
                throw new AssertionError("deleted store header remained on disk");
            RecordStore fresh = RecordStore.openRecordStore("settings", true);
            if (fresh.getNumRecords() != 0) throw new AssertionError("deleted store data leaked into recreated store");
            fresh.closeRecordStore();
            return;
        }
        if ("cache-race".equals(mode)) {
            final java.util.concurrent.CountDownLatch ready = new java.util.concurrent.CountDownLatch(4);
            final java.util.concurrent.CountDownLatch start = new java.util.concurrent.CountDownLatch(1);
            final java.util.concurrent.atomic.AtomicReference<Throwable> failure =
                    new java.util.concurrent.atomic.AtomicReference<Throwable>();
            Thread[] threads = new Thread[4];
            for (int t = 0; t < threads.length; t++) {
                threads[t] = new Thread(new Runnable() {
                    public void run() {
                        ready.countDown();
                        try {
                            start.await();
                            for (int i = 0; i < 80; i++) {
                                RecordStore r = RecordStore.openRecordStore("settings", false);
                                if (!args[2].equals(new String(r.getRecord(1), "UTF-8")))
                                    throw new AssertionError("concurrent RMS reopen data mismatch");
                                r.closeRecordStore();
                            }
                        } catch (Throwable e) {
                            failure.compareAndSet(null, e);
                        }
                    }
                });
                threads[t].start();
            }
            ready.await();
            start.countDown();
            for (Thread thread : threads) thread.join();
            if (failure.get() != null) throw new AssertionError("concurrent RMS open/close failed", failure.get());
            RecordStore finalStore = RecordStore.openRecordStore("settings", false);
            if (!args[2].equals(new String(finalStore.getRecord(1), "UTF-8")))
                throw new AssertionError("final concurrent RMS data mismatch");
            finalStore.closeRecordStore();
            return;
        }
        if ("cache-bytes".equals(mode)) {
            RecordStore r = RecordStore.openRecordStore("large", true);
            byte[] data = new byte[300 * 1024];
            java.util.Arrays.fill(data, (byte) 7);
            r.addRecord(data, 0, data.length);
            r.closeRecordStore();
            java.lang.reflect.Field managerField = RecordStore.class.getDeclaredField("recordStoreManager");
            managerField.setAccessible(true);
            Object manager = managerField.get(null);
            java.lang.reflect.Field cacheField = manager.getClass().getDeclaredField("closedStoreCache");
            cacheField.setAccessible(true);
            java.util.Map cache = (java.util.Map) cacheField.get(manager);
            if (cache.size() != 0) throw new AssertionError("oversized store retained in cache");
            RecordStore again = RecordStore.openRecordStore("large", false);
            if (again.getRecord(1).length != 300 * 1024)
                throw new AssertionError("oversized store failed to reload from disk");
            again.closeRecordStore();
            if (cache.size() != 0) throw new AssertionError("oversized store re-entered cache");
            return;
        }
        if ("cache-lru".equals(mode)) {
            for (int i = 0; i < 17; i++) {
                RecordStore r = RecordStore.openRecordStore("store" + i, true);
                byte[] data = ("VALUE_" + i).getBytes("UTF-8");
                r.addRecord(data, 0, data.length);
                r.closeRecordStore();
            }
            java.lang.reflect.Field managerField = RecordStore.class.getDeclaredField("recordStoreManager");
            managerField.setAccessible(true);
            Object manager = managerField.get(null);
            java.lang.reflect.Field cacheField = manager.getClass().getDeclaredField("closedStoreCache");
            cacheField.setAccessible(true);
            java.util.Map cache = (java.util.Map) cacheField.get(manager);
            if (cache.size() != 16) throw new AssertionError("closed cache bound violated");
            RecordStore first = RecordStore.openRecordStore("store0", false);
            if (!"VALUE_0".equals(new String(first.getRecord(1), "UTF-8")))
                throw new AssertionError("evicted store did not reload from disk");
            first.closeRecordStore();
            if (cache.size() != 16) throw new AssertionError("LRU cache size changed");
            return;
        }
        if ("corrupt".equals(mode)) {
            try {
                RecordStore.openRecordStore("settings", true);
                throw new AssertionError("Corrupt RMS file silently replaced");
            } catch (RecordStoreException expected) {
                return;
            }
        }
        throw new AssertionError("unknown command");
    }
}
"""


class RmsPersistenceAuditTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="jarbox-rms-")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)

    def compile(self):
        if not shutil.which("javac") or not shutil.which("java"):
            self.skipTest("JDK required")
        target = self.root / "classes"
        target.mkdir(exist_ok=True)
        sources = sorted(str(p) for p in RMS.rglob("*.java"))
        harness = self.root / "RmsSmoke.java"
        harness.write_text(HARNESS, encoding="utf-8")
        subprocess.run(
            ["javac", "--release", "8", "-d", str(target), *sources, str(harness)],
            check=True, text=True, capture_output=True, timeout=65)
        return target

    def run_case(self, classes, root, mode, value=""):
        return subprocess.run(
            ["java", "-cp", str(classes), "RmsSmoke", str(root), mode, value],
            check=True, text=True, capture_output=True, timeout=15)

    def test_two_install_roots_do_not_share_save_data_or_logs(self):
        classes = self.compile()
        a, b = self.root / "install-A", self.root / "install-B"
        a.mkdir()
        b.mkdir()
        self.run_case(classes, a, "write", "ACCOUNT_A_PRIVATE")
        self.run_case(classes, b, "write", "ACCOUNT_B_PRIVATE")
        self.run_case(classes, a, "read", "ACCOUNT_A_PRIVATE")
        self.run_case(classes, b, "read", "ACCOUNT_B_PRIVATE")
        self.run_case(classes, a, "reopen", "ACCOUNT_A_PRIVATE")
        self.run_case(classes, b, "reopen", "ACCOUNT_B_PRIVATE")
        log_a = (a / "rms-events.log").read_text()
        log_b = (b / "rms-events.log").read_text()
        self.assertIn("RMS_SAVE", log_a)
        self.assertIn("RMS_SAVE", log_b)
        self.assertIn("RMS_CREATE", log_a)
        for contents in (log_a, log_b):
            self.assertNotIn("ACCOUNT_", contents)
            self.assertNotIn("settings", contents)
            self.assertNotIn(str(self.root), contents)
            self.assertLessEqual(len(contents.encode()), 128 * 1024)
        # Both roots contain their own record bytes, never the other game's.
        file_a = (a / "rms/settings.1.rsr").read_bytes()
        file_b = (b / "rms/settings.1.rsr").read_bytes()
        self.assertIn(b"ACCOUNT_A_PRIVATE", file_a)
        self.assertNotIn(b"ACCOUNT_B_PRIVATE", file_a)
        self.assertIn(b"ACCOUNT_B_PRIVATE", file_b)
        self.assertNotIn(b"ACCOUNT_A_PRIVATE", file_b)

    def test_closed_store_cache_and_lru_eviction(self):
        classes = self.compile()
        root = self.root / "cache"
        root.mkdir()
        self.run_case(classes, root, "write", "CACHE_PRIVATE")
        self.run_case(classes, root, "cache", "CACHE_PRIVATE")
        self.run_case(classes, root, "cache-lru")

    def test_concurrent_open_close_keeps_single_consistent_store(self):
        classes = self.compile()
        root = self.root / "cache-race"
        root.mkdir()
        self.run_case(classes, root, "write", "RACE_PRIVATE")
        self.run_case(classes, root, "cache-race", "RACE_PRIVATE")

    def test_cache_byte_limit_and_eviction(self):
        classes = self.compile()
        root = self.root / "cache-bytes"
        root.mkdir()
        self.run_case(classes, root, "cache-bytes")

    def test_corrupted_header_and_record_are_preserved_not_reinitialized(self):
        classes = self.compile()
        for corrupt_file in ("settings.rsh", "settings.1.rsr"):
            with self.subTest(file=corrupt_file):
                dest = self.root / corrupt_file.replace(".", "_")
                dest.mkdir()
                self.run_case(classes, dest, "write", "IMPORTANT_SAVE")
                record = dest / "rms" / corrupt_file
                record.write_bytes(b"BROKEN_ORIGINAL_DO_NOT_DELETE")
                self.run_case(classes, dest, "corrupt")
                self.assertEqual(record.read_bytes(), b"BROKEN_ORIGINAL_DO_NOT_DELETE")
                self.assertIn("RMS_READ_ERROR",
                              (dest / "rms-events.log").read_text())


if __name__ == "__main__":
    unittest.main()
