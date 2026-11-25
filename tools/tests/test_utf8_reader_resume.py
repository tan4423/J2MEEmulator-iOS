"""Run the production decoder against a CLDC-shaped StreamReader on host."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
READER = ROOT / "J2MEEmulator/RuntimePatches/com/sun/cldc/i18n/j2me/UTF_8_Reader.java"
STUB = r"""
package com.sun.cldc.i18n;
import java.io.*;
public abstract class StreamReader extends Reader {
 public InputStream in;
 public Reader open(InputStream input,String enc) throws UnsupportedEncodingException {in=input;return this;}
 public boolean ready(){try{return in.available()>0;}catch(IOException e){return false;}}
 public abstract int sizeOf(byte[] b,int off,int len);
}
"""
TEST = r"""
import java.io.*;
import java.net.SocketTimeoutException;
import java.util.Random;
import com.sun.cldc.i18n.j2me.UTF_8_Reader;
public class ReaderTest {
 static void check(boolean b){if(!b)throw new AssertionError();}
 static class Flaky extends InputStream {
  final byte[] data; int pos, failAt, closes; boolean failed;
  Flaky(byte[] d,int f){data=d;failAt=f;}
  public int available(){return data.length-pos;}
  public int read() throws IOException {if(pos==failAt&&!failed){failed=true;throw new SocketTimeoutException();}return pos==data.length?-1:data[pos++]&255;}
  public void close(){closes++;}
 }
 public static void main(String[] args)throws Exception {
  UTF_8_Reader r=new UTF_8_Reader();
  Flaky s=new Flaky("A\u20ac\ud83d\ude03Z".getBytes("UTF-8"),2);
  r.open(s,"UTF-8");char[] b=new char[20];
  check(r.read(b,0,b.length)==1 && b[0]=='A');
  try{r.read();throw new AssertionError();}catch(SocketTimeoutException expected){}
  check(r.read()==0x20ac);check(r.read()==0xd83d);check(r.ready());check(r.read()==0xde03);check(r.read()=='Z');check(r.read()==-1);
  r.close();r.close();check(s.closes==1);try{r.read();throw new AssertionError();}catch(IOException expected){}
  r.open(new ByteArrayInputStream(new byte[]{(byte)0xf0,(byte)0x80,(byte)0x80,(byte)0x80,'X'}),"UTF-8");check(r.read()==0xfffd&&r.read()=='X');
  byte[] malformed={(byte)0xe2,'Q'};r.open(new ByteArrayInputStream(malformed),"UTF-8");check(r.read()==0xfffd&&r.ready()&&r.read()=='Q');
  r.open(new ByteArrayInputStream("\ud83d\ude03".getBytes("UTF-8")),"UTF-8");check(r.read()==0xd83d&&r.ready()&&r.read()==0xde03&&!r.ready());
  Random rand=new Random(37);for(int i=0;i<3000;i++){byte[] bytes=new byte[rand.nextInt(65)];rand.nextBytes(bytes);r.open(new ByteArrayInputStream(bytes),"UTF-8");int count=0;while(r.read()!=-1)count++;check(r.sizeOf(bytes,0,bytes.length)==count);}
 }
}
"""
class UTF8ReaderResumeTest(unittest.TestCase):
    def test_timeout_resume_pending_chars_and_size(self):
        javac, java = shutil.which("javac"), shutil.which("java")
        if not javac or not java:
            self.skipTest("JDK unavailable")
        with tempfile.TemporaryDirectory() as td:
            root=Path(td)
            for name, content in (("StreamReader.java", STUB), ("UTF_8_Reader.java", READER.read_text()), ("ReaderTest.java", TEST)):
                (root/name).write_text(content)
            subprocess.run([javac, "-source", "8", "-target", "8", "-d", td, *map(str,root.glob("*.java"))],check=True,timeout=30)
            subprocess.run([java,"-cp",td,"ReaderTest"],check=True,timeout=10)

if __name__=="__main__":
    unittest.main()
