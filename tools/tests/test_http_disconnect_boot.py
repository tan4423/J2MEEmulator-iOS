"""Execute the production null-check against a minimal miniJVM-shaped superclass.

The real boot API and class replacement are verified separately by Codemagic.
No remote HTTP requests, game code or iOS execution are involved.
"""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
PATCH = ROOT / "J2MEEmulator/RuntimePatches/org/mini/urlhandler/HttpHandler.java"

SUPERCLASS = """
package org.mini.urlhandler;
import java.io.*;
import java.net.*;
abstract class TestHttpURLConnection extends java.net.HttpURLConnection {
    protected Closeable connection;
    protected TestHttpURLConnection(URL url) { super(url); }
    public void connect() throws IOException {}
    public boolean usingProxy() { return false; }
}
"""

MAIN = """
package org.mini.urlhandler;
import java.io.*;
import java.net.*;
public class DisconnectTest {
    public static void main(String[] args) throws Exception {
        HttpHandler.HttpURLConnectionImpl h =
            new HttpHandler.HttpURLConnectionImpl(new URL("http://localhost/"));
        h.disconnect();  // failed/not-started connection
        h.disconnect();  // repeated null cleanup
        final int[] closed = {0};
        h.connection = new Closeable() {
            public void close() { closed[0]++; }
        };
        h.disconnect();
        if (closed[0] != 1) throw new AssertionError("close was skipped");
        h.connection = new Closeable() {
            public void close() throws IOException { throw new IOException("fixture"); }
        };
        try {
            h.disconnect();
            throw new AssertionError("IOException swallowed");
        } catch (RuntimeException expected) {
            if (!(expected.getCause() instanceof IOException)) throw expected;
        }
    }
}
"""

class HttpDisconnectBootTest(unittest.TestCase):
    def test_null_and_real_connection_cleanup(self):
        javac, java = shutil.which("javac"), shutil.which("java")
        if not javac or not java:
            self.skipTest("JDK unavailable")
        source = PATCH.read_text()
        # Only substitute the superclass in the host fixture. Compile and
        # execute the exact production disconnect body.
        source = source.replace("extends HttpURLConnection {", "extends TestHttpURLConnection {")
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            for name, text in (("HttpHandler.java", source),
                               ("TestHttpURLConnection.java", SUPERCLASS),
                               ("DisconnectTest.java", MAIN)):
                (root / name).write_text(text)
            subprocess.run([javac, "-d", td, *map(str, root.glob("*.java"))], check=True, timeout=30)
            subprocess.run([java, "-cp", td, "org.mini.urlhandler.DisconnectTest"], check=True, timeout=10)

    def test_packaged_boot_patch(self):
        ci = (ROOT / "codemagic.yaml").read_text()
        self.assertIn('diff -u "$RUNNER_TEMP/http-original-api" "$RUNNER_TEMP/http-patched-api"', ci)
        self.assertIn('jar uf "$jars/minijvm_rt.jar" -C "$http_classes" "$http_entry"', ci)
        self.assertIn('cmp "$http_original/$http_entry" "$http_classes/$http_entry"', ci)

if __name__ == "__main__":
    unittest.main()
