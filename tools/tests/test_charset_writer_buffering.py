"""Execute the production OutputStreamWriter with a CLDC-shaped converter.

The desktop fixture uses an intentionally per-code-point encoder and actual
PrintWriter/BufferedOutputStream. It checks byte delivery, not TCP packets
or remote game responses. CI separately verifies the packaged boot class.
"""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
WRITER = ROOT / "J2MEEmulator/RuntimePatches/java/io/OutputStreamWriter.java"

HELPER = r"""
package fixture;
import java.io.*;
final class Helper {
    static Writer getStreamWriter(OutputStream os) {
        try { return getStreamWriter(os, "UTF-8"); }
        catch (UnsupportedEncodingException e) { throw new AssertionError(e); }
    }
    static Writer getStreamWriter(final OutputStream os, String enc)
            throws UnsupportedEncodingException {
        if (os == null) throw new NullPointerException();
        if (!"UTF-8".equals(enc)) throw new UnsupportedEncodingException(enc);
        return new Writer() {
            public void write(char[] c, int off, int n) throws IOException {
                String s = new String(c, off, n);
                for (int i=0; i<s.length();) {
                    int cp=s.codePointAt(i);
                    byte[] bytes=new String(Character.toChars(cp)).getBytes("UTF-8");
                    os.write(bytes,0,bytes.length);
                    i+=Character.charCount(cp);
                }
            }
            public void flush() throws IOException { os.flush(); }
            public void close() throws IOException { os.close(); }
        };
    }
}
"""

MAIN = r"""
package fixture;
import java.io.*;
import java.nio.charset.StandardCharsets;
import java.util.Arrays;
public class WriterTest {
    static class Sink extends OutputStream {
        ByteArrayOutputStream bytes = new ByteArrayOutputStream();
        int writes, flushes, closes, attempts;
        boolean fail;
        public void write(int b) throws IOException {
            write(new byte[]{(byte)b},0,1);
        }
        public void write(byte[] b, int off, int len) throws IOException {
            attempts++;
            if (fail) throw new IOException("fixture");
            writes++; bytes.write(b,off,len);
        }
        public void flush() { flushes++; }
        public void close() { closes++; }
    }
    static void check(boolean b) { if (!b) throw new AssertionError(); }
    static byte[] utf8(String s) throws Exception { return s.getBytes("UTF-8"); }
    public static void main(String[] args) throws Exception {
        Sink s=new Sink();
        PrintWriter p=new PrintWriter(new JarBoxWriter(s,StandardCharsets.UTF_8),true);
        p.println("123");
        check(s.writes==1);
        check(Arrays.equals(s.bytes.toByteArray(),utf8("123"+System.lineSeparator())));
        check(s.flushes>0 && !p.checkError());
        p.close();

        Sink t=new Sink();
        JarBoxWriter w=new JarBoxWriter(t,StandardCharsets.UTF_8);
        String unicode="A\u1ebf\u6c34\ud83d\ude03";
        w.write(unicode);
        check(t.writes==0);
        w.flush();
        check(t.writes==1 && Arrays.equals(t.bytes.toByteArray(),utf8(unicode)));
        w.write("tail");
        w.close();
        check(t.writes==2 && t.closes==1);
        check(Arrays.equals(t.bytes.toByteArray(),utf8(unicode+"tail")));
        w.close();
        check(t.closes==1);

        Sink legacy=new Sink();
        JarBoxWriter old=new JarBoxWriter(legacy,"UTF-8");
        old.write("abc");
        check(legacy.writes==3); // preserve existing CLDC timing
        old.close();

        Sink large=new Sink();
        JarBoxWriter l=new JarBoxWriter(large,StandardCharsets.UTF_8);
        char[] chars=new char[3000]; Arrays.fill(chars,'x');
        l.write(chars,0,chars.length); l.flush(); l.close();
        check(large.bytes.size()==3000 && large.writes==3);

        Sink bad=new Sink();
        JarBoxWriter b=new JarBoxWriter(bad,StandardCharsets.UTF_8);
        b.write("x"); bad.fail=true;
        try { b.close(); throw new AssertionError("flush failure swallowed"); }
        catch (IOException expected) { check(bad.closes==1 && bad.attempts==1); }
        try { b.write("z"); throw new AssertionError("writer still open"); }
        catch (IOException expected) {}
        try { new JarBoxWriter(null,StandardCharsets.UTF_8); throw new AssertionError(); }
        catch (NullPointerException expected) {}
    }
}
"""

class CharsetWriterBufferingTest(unittest.TestCase):
    def test_charset_auto_flush_coalesces_and_preserves_bytes(self):
        javac, java = shutil.which("javac"), shutil.which("java")
        if not javac or not java:
            self.skipTest("JDK unavailable")
        source = WRITER.read_text().replace("package java.io;", "package fixture;\nimport java.io.*;")
        source = source.replace("import com.sun.cldc.i18n.*;", "")
        source = source.replace("OutputStreamWriter", "JarBoxWriter")
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            for name, data in (("JarBoxWriter.java", source), ("Helper.java", HELPER), ("WriterTest.java", MAIN)):
                (root/name).write_text(data)
            subprocess.run([javac, "-d", td, *map(str,root.glob("*.java"))], check=True, timeout=30)
            subprocess.run([java, "-cp", td, "fixture.WriterTest"], check=True, timeout=10)

if __name__ == "__main__":
    unittest.main()
