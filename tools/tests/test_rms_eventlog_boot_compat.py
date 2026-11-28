"""Catch Java API mismatch in RMS metadata logging against the packaged miniJVM boot.

Compile the actual RMS logger under host Java 8. Inspect its bytecode by file
path and verify the actual boot JAR's FileOutputStream constructors by classfile
path (never use host JDK java.io.FileOutputStream for the latter).

The write/append fixture runs on a host JDK, NOT an iPhone or real miniJVM.
"""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
import zipfile

ROOT = Path(__file__).resolve().parents[2]
SRC = ROOT / "j2me_api/src/javax/microedition/rms/impl/RmsEventLog.java"
BOOT = ROOT / "J2MEEmulator/Resources/jars/minijvm_rt.jar"

DRIVER = r"""
import javax.microedition.rms.impl.RmsEventLog;
public class RmsAppendCheck {
    public static void main(String[] args) {
        System.setProperty("app.save.root", args[0]);
        RmsEventLog.note("OPEN", "private_store", -1, -1);
        RmsEventLog.note("OPEN_CACHE", "private_store", -1, -1);
        RmsEventLog.note("SAVE", "private_store", 1, 5);
        RmsEventLog.note("SAVE", "private_store", 2, 6);
    }
}
"""

class RmsEventLogBootCompatTest(unittest.TestCase):
    def test_boot_fileoutputstream_and_rms_logger_append_signature(self):
        for tool in ("javac", "java", "javap"):
            if shutil.which(tool) is None:
                self.skipTest(tool + " missing")
        with tempfile.TemporaryDirectory(prefix="jarbox-rms-boot-") as temp:
            work = Path(temp)
            classes = work / "classes"
            classes.mkdir()
            with zipfile.ZipFile(BOOT) as boot:
                # No fallback to host JDK classes: that was the original
                # test gap. A missing boot class must fail this regression.
                class_name = "java/io/FileOutputStream.class"
                self.assertIn(class_name, boot.namelist())
                boot_class = work / class_name
                boot_class.parent.mkdir(parents=True)
                boot_class.write_bytes(boot.read(class_name))
            actual_boot = subprocess.run(
                ["javap", "-p", str(boot_class)],
                capture_output=True, text=True, timeout=30)
            self.assertEqual(actual_boot.returncode, 0,
                             actual_boot.stdout + actual_boot.stderr)
            self.assertIn(
                "java.io.FileOutputStream(java.lang.String, boolean)",
                actual_boot.stdout)
            self.assertNotIn(
                "java.io.FileOutputStream(java.io.File, boolean)",
                actual_boot.stdout)

            driver = work / "RmsAppendCheck.java"
            driver.write_text(DRIVER, encoding="utf-8")
            compiled = subprocess.run(
                ["javac", "--release", "8", "-sourcepath", "", "-d",
                 str(classes), str(SRC), str(driver)],
                capture_output=True, text=True, timeout=45)
            self.assertEqual(compiled.returncode, 0,
                             compiled.stdout + compiled.stderr)

            logger_class = classes / "javax/microedition/rms/impl/RmsEventLog.class"
            bytecode = subprocess.run(
                ["javap", "-c", "-p", str(logger_class)],
                capture_output=True, text=True, timeout=30)
            self.assertEqual(bytecode.returncode, 0,
                             bytecode.stdout + bytecode.stderr)
            self.assertIn(
                "java/io/FileOutputStream.\"<init>\":(Ljava/lang/String;Z)V",
                bytecode.stdout)
            self.assertNotIn(
                "java/io/FileOutputStream.\"<init>\":(Ljava/io/File;Z)V",
                bytecode.stdout)

            save_root = work / "save"
            save_root.mkdir()
            log = save_root / "rms-events.log"
            log.write_text("PRESERVED\n", encoding="utf-8")
            ran = subprocess.run(
                ["java", "-cp", str(classes), "RmsAppendCheck", str(save_root)],
                capture_output=True, text=True, timeout=20)
            self.assertEqual(ran.returncode, 0,
                             ran.stdout + ran.stderr)
            rows = log.read_text(encoding="utf-8")
            self.assertTrue(rows.startswith("PRESERVED\n"))
            self.assertEqual(rows.count("RMS_SAVE"), 2)
            self.assertNotIn("RMS_OPEN", rows)
            self.assertNotIn("RMS_OPEN_CACHE", rows)
            self.assertNotIn("private_store", rows)
            self.assertNotIn(str(save_root), rows)

    def test_source_cannot_regress_to_unsupported_file_boolean_ctor(self):
        code = SRC.read_text(encoding="utf-8")
        self.assertIn("new FileOutputStream(log.getPath(), true)", code)
        self.assertNotIn("new FileOutputStream(log, true)", code)

if __name__ == "__main__":
    unittest.main()
