#!/usr/bin/env python3
"""Send a bounded command to a specific owner-local JarBox session."""
import argparse,json,pathlib,socket,stat,os,uuid
def main():
    p=argparse.ArgumentParser()
    p.add_argument("session",type=pathlib.Path)
    p.add_argument("command",choices=("status","snapshot","tap","key","stop","chat"))
    p.add_argument("args",nargs="*")
    a=p.parse_args()
    expected={"status":0,"snapshot":0,"tap":2,"key":1,"stop":0,"chat":1}
    if len(a.args)!=expected[a.command]:p.error("incorrect arguments")
    directory=a.session.resolve(strict=True)
    st=directory.stat()
    if st.st_uid!=os.getuid() or st.st_mode&0o077:p.error("session is not private")
    target=directory/"control.sock"
    st=target.lstat()
    if not stat.S_ISSOCK(st.st_mode) or st.st_uid!=os.getuid() or st.st_mode&0o077:p.error("invalid control socket")
    payload=" ".join([a.command,*a.args]).encode("ascii")
    if len(payload)>95:p.error("command too long")
    with socket.socket(socket.AF_UNIX,socket.SOCK_DGRAM) as c:
        c.bind("\0jarbox-lab-"+uuid.uuid4().hex)
        c.settimeout(3)
        c.connect(str(target))
        c.send(payload)
        response=json.loads(c.recv(4096))
    print(json.dumps(response))
    if response["state"] not in ("ok","queued","stopping"):raise SystemExit(1)
if __name__=="__main__":main()
