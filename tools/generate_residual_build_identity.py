"""Bind the experimental native residual to the exact packaged patched jars.

Run only after the checked-in boot/API patch recipe. No game archive is
required or copied. This is identity, not a semantic proof of arbitrary APIs.
"""
import hashlib
import sys
from pathlib import Path

def generate(root, output):
    lines=['/* Generated from the patched build jars. Do not commit. */',
           '#ifndef JARBOX_RESIDUAL_BUILD_IDENTITY_H','#define JARBOX_RESIDUAL_BUILD_IDENTITY_H']
    for filename,symbol in [('j2me_api.jar','jbr_bundled_api_sha256'),('minijvm_rt.jar','jbr_bundled_boot_sha256')]:
        data=(root/filename).read_bytes()
        if not data or len(data)>16*1024*1024:raise ValueError('invalid bundled archive size')
        digest=hashlib.sha256(data).digest()
        lines.append('static const unsigned char '+symbol+'[32]={'+','.join('0x%02x'%v for v in digest)+'};')
    output.write_text('\n'.join(lines+['#endif','']))
if __name__=='__main__':
    generate(Path(sys.argv[1]),Path(sys.argv[2]))
