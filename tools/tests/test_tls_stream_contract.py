"""Compile the production TLS stream helpers with deterministic mbedTLS I/O."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT=Path(__file__).resolve().parents[2]
TLS=ROOT/"J2MEEmulator/minijvm/utils/https/ssl_client.c"
PRE=r"""
#include <stdio.h>
#include <stddef.h>
typedef struct {int fd;} Net;
typedef struct {Net server_fd;int initialized,connected,ssl,cacert,conf,ctr_drbg,entropy;} SSLC_Entry;
#define MBEDTLS_ERR_SSL_WANT_READ -10
#define MBEDTLS_ERR_SSL_WANT_WRITE -11
#define SSL_LOG_PRINTF(...) ((void)0)
static int steps[8],at,freed,notified,failed,offsets[8];
static const unsigned char *base;
static int jarbox_net_http_status(void){return failed;}
static int mbedtls_ssl_write(int *s,const unsigned char *p,size_t n){
 (void)s;(void)n;offsets[at]=(int)(p-base);return steps[at++];
}
static int mbedtls_ssl_read(int *s,unsigned char *p,size_t n){(void)s;(void)p;(void)n;return steps[at++];}
static void mbedtls_ssl_close_notify(int *s){(void)s;notified++;}
static void mbedtls_net_free(Net *n){n->fd=-1;freed++;}
static void mbedtls_x509_crt_free(int *s){(void)s;freed++;}
static void mbedtls_ssl_free(int *s){(void)s;freed++;}
static void mbedtls_ssl_config_free(int *s){(void)s;freed++;}
static void mbedtls_ctr_drbg_free(int *s){(void)s;freed++;}
static void mbedtls_entropy_free(int *s){(void)s;freed++;}
"""
MAIN=r"""
int main(void){
 SSLC_Entry e={.server_fd={3},.initialized=1,.connected=1};
 char b[8]={0};base=(const unsigned char*)b;
 steps[0]=2;steps[1]=MBEDTLS_ERR_SSL_WANT_WRITE;steps[2]=6;
 if(sslc_write(&e,b,8)!=8||at!=3||offsets[0]!=0||offsets[1]!=2||offsets[2]!=2)return 1;
 at=0;steps[0]=0;if(sslc_read(&e,b,1)!=-1)return 2;
 at=0;steps[0]=MBEDTLS_ERR_SSL_WANT_READ;steps[1]=1;if(sslc_read(&e,b,1)!=1||at!=2)return 3;
 failed=2;at=0;if(sslc_write(&e,b,1)!=-1||sslc_read(&e,b,1)!=-1||at!=0)return 4;
 if(sslc_close(&e)||sslc_close(&e)||freed!=6||notified||e.connected||e.initialized)return 5;
 failed=0;e.initialized=1;e.connected=1;e.server_fd.fd=4;
 if(sslc_close(&e)||freed!=12||notified!=1)return 6;
 return 0;
}
"""
class TLSStreamContractTest(unittest.TestCase):
    def test_partial_write_eof_and_sequential_close(self):
        cc=shutil.which("cc")
        if not cc:self.skipTest("C compiler unavailable")
        source=TLS.read_text()
        start=source.index("int sslc_write(")
        with tempfile.TemporaryDirectory() as td:
            c=Path(td)/"tls.c";exe=Path(td)/"tls"
            c.write_text(PRE+source[start:]+MAIN)
            subprocess.run([cc,"-std=c11","-Wall","-Wextra","-Werror",str(c),"-o",str(exe)],check=True,timeout=30)
            subprocess.run([str(exe)],check=True,timeout=10)
if __name__=="__main__":
    unittest.main()
