"""Compile the exact native registry block and use real local sockets.

Tests owner stop, immediate peer EOF, late admission rejection, close/reuse,
final descriptor drain and cancellation of a blocked receive. No game server.
"""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT=Path(__file__).resolve().parents[2]
CORE=ROOT/"J2MEEmulator/minijvm/jvm"
NET=ROOT/"J2MEEmulator/minijvm/utils/https/mbedtls/library/net_sockets.c"
PRE=r"""
#define _POSIX_C_SOURCE 200809L
#include <sys/types.h>
#include <sys/socket.h>
#include <unistd.h>
#include <fcntl.h>
#include <poll.h>
#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include "jarbox_net_lifecycle.h"
typedef struct {int fd;} mbedtls_net_context;
"""
MAIN=r"""
#define CHECK(x) do {if(!(x)){fprintf(stderr,"failure %d\n",__LINE__);return 1;}}while(0)
int main(void){
    int va=1,vb=2;
    JarBoxSession *a=jarbox_session_create(&va), *b=jarbox_session_create(&vb);
    CHECK(a&&b);
    int sa[2],sb[2],sc[2];
    CHECK(socketpair(AF_UNIX,SOCK_STREAM,0,sa)==0);
    CHECK(socketpair(AF_UNIX,SOCK_STREAM,0,sb)==0);
    JarBoxNetScope prior=jarbox_net_scope_enter(a,0);
    CHECK(jarbox_net_register(sa[0])==sa[0]);
    int copy=jarbox_net_duplicate_for_tls(sa[0]);
    CHECK(copy>=0&&copy!=sa[0]);
    jarbox_net_scope_leave(prior);
    prior=jarbox_net_scope_enter(b,0);
    CHECK(jarbox_net_register(sb[0])==sb[0]);
    CHECK(jarbox_net_duplicate_for_tls(sa[0])<0);
    jarbox_net_scope_leave(prior);
    CHECK(jarbox_net_stop_owner(a)==2);
    char c=0;
    CHECK(recv(sa[1],&c,1,0)==0);
    CHECK(send(sb[1],"b",1,0)==1&&recv(sb[0],&c,1,0)==1&&c=='b');
    CHECK(fcntl(sa[0],F_GETFD)>=0);
    prior=jarbox_net_scope_enter(a,0);
    CHECK(socketpair(AF_UNIX,SOCK_STREAM,0,sc)==0);
    CHECK(jarbox_net_register(sc[0])==-1&&fcntl(sc[0],F_GETFD)<0);
    CHECK(jarbox_net_socket(AF_INET,SOCK_STREAM,0)<0);
    jarbox_net_scope_leave(prior);
    mbedtls_net_context ctx={copy};
    jarbox_net_close_context(&ctx,1);
    CHECK(ctx.fd==-1);
    jarbox_net_close_context(&ctx,1);
    CHECK(jarbox_net_release_owner(a)==1);
    CHECK(fcntl(sa[0],F_GETFD)<0);
    CHECK(jarbox_net_release_owner(a)==0);
    CHECK(send(sb[1],"c",1,0)==1&&recv(sb[0],&c,1,0)==1&&c=='c');
    mbedtls_net_context cb={sb[0]};
    jarbox_net_close_context(&cb,1);
    CHECK(jarbox_net_release_owner(b)==0);
    close(sa[1]);close(sb[1]);close(sc[1]);
    // Real TCP loopback: a connect deadline is enforced, blocking flags
    // restored on success, and stopping wakes the connected peer.
    int listener=socket(AF_INET,SOCK_STREAM,0);
    CHECK(listener>=0);
    struct sockaddr_in addr={0};
    addr.sin_family=AF_INET;
    // Darwin strict POSIX feature mode hides the BSD INADDR_LOOPBACK macro.
    CHECK(inet_pton(AF_INET,"127.0.0.1",&addr.sin_addr)==1);
    CHECK(bind(listener,(struct sockaddr*)&addr,sizeof(addr))==0);
    CHECK(listen(listener,2)==0);
    socklen_t sz=sizeof(addr);
    CHECK(getsockname(listener,(struct sockaddr*)&addr,&sz)==0);
    prior=jarbox_net_scope_enter(b,500);
    int fd=jarbox_net_socket(AF_INET,SOCK_STREAM,0);
    CHECK(fd>=0);
    CHECK(jarbox_net_connect_fd(fd,(struct sockaddr*)&addr,sz,jarbox_net_connect_deadline())==0);
    CHECK(!(fcntl(fd,F_GETFL)&O_NONBLOCK));
    int peer=accept(listener,NULL,NULL);
    CHECK(peer>=0);
    int fd2=jarbox_net_socket(AF_INET,SOCK_STREAM,0);
    CHECK(fd2>=0);
    CHECK(jarbox_net_connect_fd(fd2,(struct sockaddr*)&addr,sz,jarbox_net_now_ms()-1)<0 && errno==ETIMEDOUT);
    jarbox_net_scope_leave(prior);
    CHECK(jarbox_net_shutdown_fd(&fd,SHUT_WR)==0);
    CHECK(recv(peer,&c,1,0)==0);
    CHECK(send(peer,"d",1,0)==1&&recv(fd,&c,1,0)==1&&c=='d');
    CHECK(jarbox_net_stop_owner(b)==2);
    CHECK(jarbox_net_release_owner(b)==2);
    close(peer);close(listener);
    jarbox_session_release(a);jarbox_session_release(b);
    return 0;
}
"""
class SocketSessionLifecycleTest(unittest.TestCase):
    def test_registry_peer_eof_and_isolation(self):
        cc=shutil.which("cc")
        if not cc:self.skipTest("C compiler unavailable")
        source=NET.read_text()
        start=source.index("/* JARBOX_NET_LIFECYCLE_BEGIN")
        end=source.index("/* JARBOX_NET_LIFECYCLE_END",start)
        with tempfile.TemporaryDirectory() as td:
            c=Path(td)/"test.c";exe=Path(td)/"test"
            c.write_text(PRE+source[start:end]+MAIN)
            subprocess.run([cc,"-std=c11","-Wall","-Wextra","-pthread","-I",str(CORE),
                            str(c),"-o",str(exe)],check=True,timeout=30)
            subprocess.run([str(exe)],check=True,timeout=10)

    def test_stop_precedes_drain_and_gc_finalizers(self):
        bridge=(ROOT/"J2MEEmulator/NativeBridge/jvm_bridge.c").read_text()
        body=bridge.split("int jvm_bridge_request_stop_for_token(",1)[1].split("\n}",1)[0]
        self.assertIn("jarbox_net_stop_owner(owner->session)",body)
        self.assertLess(body.index("pthread_mutex_unlock(&g_bridge_lifecycle_lock)"),
                        body.index("jarbox_net_stop_owner(owner->session)"))
        self.assertLess(body.index("jarbox_net_stop_owner(owner->session)"),
                        body.index("jarbox_session_callback_done(held)"))
        destroy=(CORE/"jvm.c").read_text().split("void jvm_destroy(",1)[1].split("\ns32 call_main",1)[0]
        self.assertLess(destroy.index("jarbox_net_stop_owner"),destroy.index("thread_stop_all"))
        self.assertLess(destroy.index("gc_destroy(jvm)"),destroy.index("jarbox_net_release_owner"))
        self.assertLess(destroy.index("jarbox_net_release_owner"),destroy.index("jarbox_session_release"))

    def test_real_java_socket_native_abi_and_packaging(self):
        java=(ROOT/"J2MEEmulator/RuntimePatches/java/net/Socket.java").read_text()
        native=(CORE/"jni_io.c").read_text()
        for name,desc in (("jarboxConnect0","([B[B[BII)I"),("jarboxShutdown0","([BI)I"),
                          ("jarboxRead0","([B[BII)I")):
            self.assertIn("native int "+name,java)
            self.assertIn('{"java/net/Socket", "'+name+'", "'+desc+'"',native)
        self.assertIn("while (sent < len)",java)
        self.assertIn("public boolean isConnected() { return isConnected; }",java)
        self.assertIn("public boolean isClosed() { return fd == null; }",java)
        self.assertIn("public boolean isInputShutdown() { return inputShutdown; }",java)
        self.assertIn("public boolean isOutputShutdown() { return outputShutdown; }",java)
        self.assertIn("Socket.this.close()",java)
        self.assertIn("throw new SocketTimeoutException",java)
        self.assertIn("ntohs(a->sin_port)",native)
        self.assertIn("ntohs(a->sin6_port)",native)
        ci=(ROOT/"codemagic.yaml").read_text()
        self.assertIn('comm -23 "$RUNNER_TEMP/socket-old-api"',ci)
        self.assertIn('jar uf "$jars/minijvm_rt.jar" -C "$socket_new" .',ci)

if __name__=="__main__":unittest.main()
