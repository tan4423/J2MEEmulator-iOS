"""Run the actual MiniJVM MIDlet against a private loopback TCP peer."""
import os, pathlib, socket, subprocess, sys, threading
root=pathlib.Path(sys.argv[1]).resolve()
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
    args=[root/"jarbox-lab",root/"jars/minijvm_rt.jar",root/"jars/j2me_api.jar",root/"fixture/fixture.jar",root/"fixture/save",root/"fixture/trace.csv","240","320","graph"]
    result=subprocess.run([str(x) for x in args],env=env,timeout=90)
    worker.join(3)
    assert result.returncode==0 and not worker.is_alive() and not errors,(result.returncode,errors)
print("LAB_LOOPBACK_PEER_PASS")
