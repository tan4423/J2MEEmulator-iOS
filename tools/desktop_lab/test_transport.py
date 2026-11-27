"""Run the actual MiniJVM MIDlet against a private loopback TCP peer."""
import os, pathlib, socket, subprocess, sys, threading, time, json, tempfile, uuid
root=pathlib.Path(sys.argv[1]).resolve()
mode=sys.argv[2] if len(sys.argv)>2 else "graph"
assert mode in ("graph","plain","logic","control","sink","map","lookup")
map_test=mode=="map"
lookup_test=mode=="lookup"
sink=mode in ("sink","map","lookup")
control=mode in ("control","sink","map","lookup")
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
            if map_test or lookup_test:
                env["JARBOX_LAB_TEST_MAP"]="1"
                env["JARBOX_LAB_TEST_MONITORS"]="1"
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
                    assert cmd("profile counters")["state"]=="ok"
                    assert cmd("status")["graph_enabled"]==0
                    assert cmd("profile graph")["state"]=="ok"
                    assert cmd("status")["graph_enabled"]==1
                    assert cmd("snapshot")["state"]=="ok"
                    assert (private/"control-frame.png").read_bytes().startswith(b"\x89PNG\r\n\x1a\n")
                    if lookup_test:
                        # A/B/A the q3 fast path while keeping the level-1 sink constant.
                        # The synthetic Class_hii fixture has the same 17-byte q3/m3
                        # shape and checks valid, overflow, null and OOB interpreter fallback.
                        assert cmd("lookup on")["state"]=="refused"
                        a=cmd("status")
                        assert a["lookup_requested"]==0 and a["sink_requested"]==0
                        assert cmd("sink on")["state"]=="ok"
                        def next_paint(last):
                            assert cmd("key enter")["state"]=="queued"
                            deadline=time.monotonic()+8
                            while True:
                                now=cmd("status")
                                if now["paints"]>last["paints"] and now["sink_paints"]>last["sink_paints"]:return now
                                assert time.monotonic()<deadline,(last,now)
                                time.sleep(.05)
                        a1=a
                        for _ in range(2):a1=next_paint(a1)
                        assert a1["map_q3"]==a["map_q3"]==0,(a,a1)
                        assert a1["sink_requested"]==1 and a1["sink_invalid"]==0
                        assert cmd("lookup on")["state"]=="ok"
                        b=cmd("status")
                        assert b["lookup_requested"]==1
                        for _ in range(10):b=next_paint(b)
                        assert b["map_q3"]-a1["map_q3"]>=64,(a1,b)
                        assert b["map_m3"]==a1["map_m3"] and b["sink_faults"]==0 and b["sink_invalid"]==0,(a1,b)
                        assert cmd("lookup off")["state"]=="ok"
                        c=cmd("status")
                        for _ in range(2):c=next_paint(c)
                        assert c["map_q3"]==b["map_q3"] and c["lookup_requested"]==0,(b,c)
                        assert c["sink_requested"]==1 and c["sink_faults"]==0 and c["sink_invalid"]==0
                        assert cmd("sink off")["state"]=="ok"
                        assert cmd("key enter")["state"]=="queued"
                        deadline=time.monotonic()+8
                        while True:
                            d=cmd("status")
                            if d["frames"]>c["frames"]:break
                            assert time.monotonic()<deadline,(c,d)
                            time.sleep(.05)
                        assert d["paints"]>c["paints"] and d["sink_requested"]==0 and d["lookup_requested"]==0
                        assert d["sink_faults"]==0 and d["sink_invalid"]==0
                        print("LAB_ARRAY_LOOKUP_ABA_PASS",json.dumps({"a1":a1,"b":b,"a2":c,"restored":d}))
                    if sink and not lookup_test:
                        # Synthetic fixtures never authorize exact real-game residual execution.
                        assert cmd("sink residual")["state"]=="refused"
                        a=cmd("status")
                        assert not a["vector_enabled"] and a["vector_hits"]==0
                        if map_test:assert cmd("vector on")["state"]=="ok"
                        else:assert cmd("vector on")["state"]=="refused"
                        assert a["residual_plans"]==a["residual_calls"]==a["residual_regions"]==0
                        assert cmd("sink map" if map_test else "sink on")["state"]=="ok"
                        assert cmd("key enter")["state"]=="queued"
                        deadline=time.monotonic()+8
                        while True:
                            b=cmd("status")
                            if b["sink_paints"]>a["sink_paints"]:break
                            assert time.monotonic()<deadline
                            time.sleep(.1)
                        assert b["paints"]>a["paints"] and b["frames"]==a["frames"]
                        assert b["sink_draws"]>a["sink_draws"] and b["sink_invalid"]==0,(a,b)
                        if map_test:
                            assert b["map_q3"]-a["map_q3"]==10,(a,b)
                            assert b["map_m3"]-a["map_m3"]==10,(a,b)
                            assert b["map_refusals"]-a["map_refusals"]==6,(a,b)
                            assert b["map_layout_builds"]-a["map_layout_builds"]==2,(a,b)
                            assert b["map_layout_hits"]>a["map_layout_hits"],(a,b)
                            assert b["vector_hits"]-a["vector_hits"]==12,(a,b)
                            assert b["vector_refusals"]-a["vector_refusals"]==6,(a,b)
                        # Idle/disconnected is normal: no synthetic Nick skill,
                        # network or update events, and no fresh paints. Stay parked.
                        if not map_test:
                            time.sleep(9)
                            idle=cmd("status")
                            assert idle["sink_requested"]==1 and idle["sink_invalid"]==0,(b,idle)
                            assert idle["skill_advances_live"]==idle["network_calls_live"]==idle["update_calls_live"]==0,idle
                            assert idle["paints"]==b["paints"] and idle["frames"]==b["frames"],(b,idle)
                            print("LAB_IDLE_HEADLESS_PASS")
                        assert cmd("vector off")["state"]=="ok"
                        assert cmd("sink off")["state"]=="ok"
                        assert cmd("key enter")["state"]=="queued"
                        deadline=time.monotonic()+8
                        while True:
                            d=cmd("status")
                            if d["frames"]>b["frames"]:break
                            assert time.monotonic()<deadline
                            time.sleep(.1)
                        assert d["paints"]>b["paints"] and d["sink_faults"]==0
                        assert d["sink_draws"]==b["sink_draws"],(b,d)
                        print("LAB_SINK_ABA_PASS",json.dumps({"a":a,"b":b,"a2":d}))
                        if map_test:
                            assert d["map_q3"]==b["map_q3"] and d["map_m3"]==b["map_m3"] and d["map_refusals"]==b["map_refusals"]
                            assert d["vector_hits"]==b["vector_hits"] and d["vector_refusals"]==b["vector_refusals"]
                            print("LAB_VECTOR_ABA_PASS")
                            print("LAB_MAP_ABA_PASS")
                    assert cmd("tap 120 137")["state"]=="queued"
                    assert result.wait(timeout=15)==0
            finally:
                if result.poll() is None:result.kill();result.wait()
            assert not (private/"control.sock").exists()
    worker.join(3)
    assert result.returncode==0 and not worker.is_alive() and not errors,(result.returncode,errors)
print("LAB_LOOPBACK_PEER_PASS")
