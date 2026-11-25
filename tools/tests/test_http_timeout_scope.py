"""Host Java test of real HTTP scope/cleanup logic, with GCF fixture.

No remote requests; native timeout enforcement is separately exercised by the
native socket tests. The exact boot ABI and packaged classes are CI checks.
"""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
PATCHES = ROOT / "J2MEEmulator/RuntimePatches/java/net"
CORE = ROOT / "J2MEEmulator/minijvm/jvm"
GCF = r"""
package fixture;
import java.io.*;
interface Connection { void close() throws IOException; }
interface HttpConnection extends Connection {
 String GET="GET", POST="POST";
 int HTTP_OK=200;
 void setRequestMethod(String method) throws IOException;
 void setRequestProperty(String key,String value) throws IOException;
 int getResponseCode() throws IOException;
 String getHeaderFieldKey(int i) throws IOException;
 String getHeaderField(String key) throws IOException;
 long getExpiration() throws IOException;
 DataInputStream openDataInputStream() throws IOException;
 DataOutputStream openDataOutputStream() throws IOException;
}
class Connector {
 static HttpConnection next;
 static int opens;
 static Connection open(String url) throws IOException { opens++; return next; }
}
class Scope {
 static int c,r,depth,failure;
 static int begin(int cm,int rm){c=cm;r=rm;depth++;failure=0;return 0;}
 static int end(){depth--;int f=failure;failure=0;return f;}
 static int status(){return failure;}
}
"""
MAIN = r"""
package fixture;
import java.io.*;
import java.net.URL;
import java.net.SocketTimeoutException;
import java.util.*;
public class HttpTest {
 static void check(boolean b){if(!b)throw new AssertionError();}
 static class Conn implements HttpConnection {
  int mode, closes, streamCloses, responseCode=200;
  boolean timeoutCloseWasScoped;
  final byte[] data;
  final Map<String,String> headers=new HashMap<String,String>();
  final ByteArrayOutputStream written=new ByteArrayOutputStream();
  Conn(int m,String s)throws Exception{mode=m;data=s.getBytes("UTF-8");}
  public void setRequestMethod(String m){}
  public void setRequestProperty(String k,String v){headers.put(k,v);}
  public int getResponseCode()throws IOException{
   if(mode==1){Scope.failure=1;throw new IOException("connect");}return responseCode;
  }
  public String getHeaderFieldKey(int i){return null;}
  public String getHeaderField(String k){return null;}
  public long getExpiration(){return System.currentTimeMillis()+60000;}
  public DataOutputStream openDataOutputStream(){return new DataOutputStream(written);}
  public DataInputStream openDataInputStream(){
   return new DataInputStream(new InputStream(){
    int pos;
    public int read()throws IOException {
     if(pos==data.length){if(mode==2)Scope.failure=2;return -1;}
     return data[pos++]&255;
    }
    public int read(byte[] b,int off,int len)throws IOException{
     if(pos==data.length){if(mode==2)Scope.failure=2;return -1;}
     int n=Math.min(len,data.length-pos);System.arraycopy(data,pos,b,off,n);pos+=n;return n;
    }
    public void close(){streamCloses++;}
   });
  }
  public void close(){closes++;timeoutCloseWasScoped=Scope.depth>0&&Scope.failure!=0;}
 }
 static class H extends HttpURLConnection {
  H(String path)throws Exception{super(new URL("http://localhost/"+path));}
  public void disconnect(){}
  boolean clean(){return connection==null&&rcvData==null&&rcvHeader.isEmpty();}
 }
 static String body(H h)throws Exception{
  ByteArrayOutputStream b=new ByteArrayOutputStream();InputStream in=h.getInputStream();int n;
  while((n=in.read())!=-1)b.write(n);
  return b.toString("UTF-8");
 }
 public static void main(String[] args)throws Exception{
  H h=new H("fail");
  check(h.getConnectTimeout()==0&&h.getReadTimeout()==0);
  h.setConnectTimeout(50);h.setReadTimeout(70);h.setDoOutput(true);
  check(h.getDoOutput()&&h.getDoInput());
  try{h.setReadTimeout(-1);throw new AssertionError();}catch(IllegalArgumentException expected){}
  try{h.setConnectTimeout(-1);throw new AssertionError();}catch(IllegalArgumentException expected){}
  Conn c=new Conn(1,"");Connector.next=c;
  try{body(h);throw new AssertionError();}catch(SocketTimeoutException expected){}
  check(h.clean()&&Scope.depth==0&&Scope.c==50&&Scope.r==70&&c.closes==1&&c.timeoutCloseWasScoped);
  c=new Conn(2,"partial");Connector.next=c;
  try{body(h);throw new AssertionError();}catch(SocketTimeoutException expected){}
  check(h.clean()&&Scope.depth==0&&c.closes==1&&c.streamCloses==1&&c.timeoutCloseWasScoped);
  c=new Conn(0,"complete");Connector.next=c;check(body(h).equals("complete")&&Scope.depth==0);
  int count=Connector.opens;check(body(new H("fail")).equals("complete")&&Connector.opens==count);
  Connector.next=new Conn(0,"one");check(body(new H("q?a=1")).equals("one"));
  Connector.next=new Conn(0,"two");check(body(new H("q?a=2")).equals("two"));
  H header=new H("q?a=1");header.setRequestProperty("X-Test","old");header.setRequestProperty("X-Test","new");
  c=new Conn(0,"private");Connector.next=c;
  check(body(header).equals("private")&&c.headers.get("x-test").equals("new"));
  H post=new H("q?a=1");post.setRequestMethod("POST");c=new Conn(0,"post");Connector.next=c;
  check(body(post).equals("post")&&c.written.size()==0);
  check(body(new H("q?a=1")).equals("one"));
 }
}
"""

class HttpTimeoutScopeTest(unittest.TestCase):
    def test_timeout_discards_partial_and_cache_is_request_specific(self):
        javac,java=shutil.which("javac"),shutil.which("java")
        if not javac or not java:
            self.skipTest("JDK unavailable")
        with tempfile.TemporaryDirectory() as td:
            root=Path(td)
            for name in ("URLConnection.java","HttpURLConnection.java"):
                s=(PATCHES/name).read_text().replace("package java.net;", "package fixture;\nimport java.net.*;")
                for line in ("import javax.microedition.io.Connection;", "import javax.microedition.io.Connector;", "import javax.microedition.io.HttpConnection;"):
                    s=s.replace(line,"")
                s=s.replace("javax.microedition.io.HttpConnection", "HttpConnection")
                s=s.replace("private static native int jarboxHttpBegin(int connectMs, int readMs);",
                    "private static int jarboxHttpBegin(int connectMs,int readMs){return Scope.begin(connectMs,readMs);}")
                s=s.replace("private static native int jarboxHttpEnd();","private static int jarboxHttpEnd(){return Scope.end();}")
                s=s.replace("private static native int jarboxHttpTimedOut();","private static int jarboxHttpTimedOut(){return Scope.status();}")
                (root/name).write_text(s)
            (root/"GCF.java").write_text(GCF)
            (root/"HttpTest.java").write_text(MAIN)
            subprocess.run([javac,"-source","8","-target","8","-d",td,*map(str,root.glob("*.java"))],check=True,timeout=30)
            subprocess.run([java,"-cp",td,"fixture.HttpTest"],check=True,timeout=10)

    def test_native_abi_and_packaging(self):
        c=(CORE/"jni_io.c").read_text()
        for name,desc in (("jarboxHttpBegin","(II)I"),("jarboxHttpEnd","()I"),("jarboxHttpTimedOut","()I")):
            self.assertIn('{"java/net/HttpURLConnection", "'+name+'", "'+desc+'"',c)
        ci=(ROOT/"codemagic.yaml").read_text()
        self.assertIn('comm -23 "$RUNNER_TEMP/http-base-old-api"',ci)
        self.assertIn('cmp "$http_base_old/$entry" "$http_base_new/$entry"',ci)

if __name__=="__main__":
    unittest.main()
