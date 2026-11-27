"""Run the actual MiniJVM MIDlet against a private loopback TCP peer."""
import os, pathlib, socket, subprocess, sys, threading, time, json, tempfile, uuid
root=pathlib.Path(sys.argv[1]).resolve()
mode=sys.argv[2] if len(sys.argv)>2 else "graph"
assert mode in ("graph","plain","logic","control")
control=mode=="control"
if control:mode="graph"
save=root/"fixture"/("save-"+mode)
save.mkdir(exist_ok=True)
trace=root/"fixture"/("trace.csv" if mode=="graph" else "trace-"+mode+".csv")
errors=[]
def recv_exact(conn,n):
    result=b""
    while len(result)<n:
        part=conn.recv(n-len(result))
        if not part: raise EOFError("premature EOF")
        result+=part
    return result
with socket.socket() as listener:
    listener.bind(("127.0.0.1",0))
    listener.listen(1)
    listener.settimeout(40)
    def serve():
        try:
            with listener.accept()[0] as conn:
                conn.settimeout(10)
                assert recv_exact(conn,4)==bytes.fromhex("12345678")
                conn.sendall(bytes.fromhex("13572468"))
        except Exception as exc: errors.append(str(exc))
    worker=threading.Thread(target=serve,daemon=True)
    worker.start()
    env=dict(os.environ,SDL_VIDEODRIVER="dummy",JARBOX_LAB_UI_FIXTURE="1",JARBOX_LAB_TEST_PORT=str(listener.getsockname()[1]))
    args=[root/"jarbox-lab",root/"jars/minijvm_rt.jar",root/"jars/j2me_api.jar",root/"fixture/fixture.jar",save,trace,"240","320",mode]
    if not control:
        result=subprocess.run([str(x) for x in args],env=env,timeout=90)
    else:
        with tempfile.TemporaryDirectory(prefix="jbctl-") as tmp:
            private=pathlib.Path(tmp)
            args[4]=private/"save";args[4].mkdir()
            args[5]=private/"trace.csv"
            env.update(JARBOX_LAB_CONTROL="1",JARBOX_LAB_TEST_CONTROL="1")
            result=subprocess.Popen([str(x) for x in args],env=env)
            try:
                with socket.socket(socket.AF_UNIX,socket.SOCK_DGRAM) as c:
                    c.bind("\0jb-test-"+uuid.uuid4().hex)
                    c.settimeout(2)
                    deadline=time.monotonic()+25
                    while not (private/"control.sock").exists():
                        assert result.poll() is None and time.monotonic()<deadline
                        time.sleep(.05)
                    def cmd(s):
                        c.sendto(s.encode(),str(private/"control.sock"))
                        return json.loads(c.recv(4096))
                    while True:
                        v=cmd("status")
                        if v["canvas"] and v["frames"]>0:break
                        assert result.poll() is None and time.monotonic()<deadline
                        time.sleep(.1)
                    assert cmd("tap 999 999")["state"]=="refused"
                    assert cmd("snapshot")["state"]=="ok"
                    assert (private/"control-frame.png").read_bytes().startswith(b"\x89PNG\r\n\x1a\n")
                    assert cmd("tap 120 137")["state"]=="queued"
                    assert result.wait(timeout=15)==0
            finally:
                if result.poll() is None:result.kill();result.wait()
            assert not (private/"control.sock").exists()
    worker.join(3)
    assert result.returncode==0 and not worker.is_alive() and not errors,(result.returncode,errors)
print("LAB_LOOPBACK_PEER_PASS")
