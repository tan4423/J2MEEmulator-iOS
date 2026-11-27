"""Run the actual MiniJVM MIDlet against a private loopback TCP peer."""
import os, pathlib, socket, subprocess, sys, threading, time, json, tempfile, uuid
root=pathlib.Path(sys.argv[1]).resolve()
mode=sys.argv[2] if len(sys.argv)>2 else "graph"
assert mode in ("graph","plain","logic","control","sink","map")
map_test=mode=="map"
sink=mode in ("sink","map")
control=mode in ("control","sink","map")
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
            if sink:env["JARBOX_LAB_TEST_SINK"]="1"
            if map_test:env["JARBOX_LAB_TEST_MAP"]="1"
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
                        if not v["canvas"]:break
                        assert result.poll() is None and time.monotonic()<deadline
                        time.sleep(.1)
                    assert cmd("chat invalid")["state"]=="refused"
                    assert cmd("chat gm37")["state"]=="queued"
                    assert cmd("chat ts")["state"]=="refused"
                    assert cmd("key f1")["state"]=="queued"
                    while True:
                        v=cmd("status")
                        if v["canvas"] and v["frames"]>0:break
                        assert result.poll() is None and time.monotonic()<deadline
                        time.sleep(.1)
                    assert cmd("tap 999 999")["state"]=="refused"
                    assert cmd("snapshot")["state"]=="ok"
                    assert (private/"control-frame.png").read_bytes().startswith(b"\x89PNG\r\n\x1a\n")
                    if sink:
                        a=cmd("status")
                        assert cmd("sink map" if map_test else "sink on")["state"]=="ok"
                        assert cmd("key enter")["state"]=="queued"
                        deadline=time.monotonic()+8
                        while True:
                            b=cmd("status")
                            if b["sink_paints"]>a["sink_paints"]:break
                            assert time.monotonic()<deadline
                            time.sleep(.1)
                        assert b["paints"]>a["paints"] and b["frames"]==a["frames"]
                        assert b["sink_draws"]>0 and b["sink_invalid"]==0
                        if map_test:
                            assert b["map_q3"]-a["map_q3"]==10,(a,b)
                            assert b["map_m3"]-a["map_m3"]==10,(a,b)
                            assert b["map_refusals"]-a["map_refusals"]==6,(a,b)
                        assert cmd("sink off")["state"]=="ok"
                        assert cmd("key enter")["state"]=="queued"
                        deadline=time.monotonic()+8
                        while True:
                            d=cmd("status")
                            if d["frames"]>b["frames"]:break
                            assert time.monotonic()<deadline
                            time.sleep(.1)
                        assert d["paints"]>b["paints"] and d["sink_faults"]==0
                        print("LAB_SINK_ABA_PASS",json.dumps({"a":a,"b":b,"a2":d}))
                        if map_test:
                            assert d["map_q3"]==b["map_q3"] and d["map_m3"]==b["map_m3"] and d["map_refusals"]==b["map_refusals"]
                            print("LAB_MAP_ABA_PASS")
                    assert cmd("tap 120 137")["state"]=="queued"
                    assert result.wait(timeout=15)==0
            finally:
                if result.poll() is None:result.kill();result.wait()
            assert not (private/"control.sock").exists()
    worker.join(3)
    assert result.returncode==0 and not worker.is_alive() and not errors,(result.returncode,errors)
print("LAB_LOOPBACK_PEER_PASS")
