import java.io.*;
import java.net.*;
import java.util.*;

/** Workload for the host multi-JVM smoke test. args: tag saveRoot mode port */
public class SmokeMain {
    static volatile int serverGot = -1;

    public static void main(String[] args) throws Exception {
        String tag = args[0], saveRoot = args[1], mode = args[2];
        int port = Integer.parseInt(args[3]);
        long sum = 0;
        // 1. allocation + GC pressure
        for (int round = 0; round < 40; round++) {
            ArrayList<byte[]> keep = new ArrayList<byte[]>();
            for (int i = 0; i < 200; i++) { byte[] b = new byte[2048]; b[0] = (byte) i; keep.add(b); }
            for (int i = 0; i < keep.size(); i++) sum += keep.get(i)[0];
        }
        // 2. threads
        final long[] part = new long[4];
        Thread[] ts = new Thread[4];
        for (int t = 0; t < 4; t++) {
            final int id = t;
            ts[t] = new Thread() { public void run() {
                long s = 0; for (int i = 0; i < 20000; i++) s += i % (id + 3); part[id] = s; } };
            ts[t].start();
        }
        for (int t = 0; t < 4; t++) { ts[t].join(); sum += part[t]; }
        // 3. loopback socket
        final ServerSocket ss = new ServerSocket(port);
        Thread srv = new Thread() { public void run() { try {
            Socket c = ss.accept(); InputStream in = c.getInputStream();
            serverGot = in.read(); c.close(); } catch (Exception e) { serverGot = -2; } } };
        srv.start();
        Socket cl = new Socket("127.0.0.1", port);
        cl.getOutputStream().write(tag.charAt(0));
        cl.getOutputStream().flush(); cl.close();
        srv.join(); ss.close();
        if (serverGot != tag.charAt(0)) { System.out.println("SOCKET_FAIL " + tag + " " + serverGot); return; }
        // 4. file in private save root
        File f = new File(saveRoot, "state.txt");
        FileOutputStream fo = new FileOutputStream(f);
        fo.write(("tag=" + tag + " sum=" + sum).getBytes()); fo.close();
        System.out.println("RESULT " + tag + " " + sum);
        // 5. long-running tail so the harness can stop this JVM mid-flight
        if (mode.equals("long")) {
            long end = System.currentTimeMillis() + 60000;
            long x = 0;
            while (System.currentTimeMillis() < end) {
                FileOutputStream beat = new FileOutputStream(saveRoot + "/heartbeat.txt");
                beat.write((x++ + "\n").getBytes()); beat.close();
                byte[] g = new byte[512]; Thread.sleep(50);
            }
        }
    }
}
