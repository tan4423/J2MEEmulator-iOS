import java.io.FileOutputStream;
import java.lang.ref.WeakReference;

/** Owner-local callback workload. No timing-sensitive callback order is assumed
 * across different GC schedules; the native shadow checks heap order per cycle. */
public final class GcIndexMain {
    static final int N = 64;
    static final int LIVE = 16000;
    static final int ROUNDS = 3;
    static Object[] live;
    static Object[] strong;
    static WeakReference[] weak;
    static Finalizable[] pending;
    static final int[] seen = new int[N * ROUNDS];
    static volatile int completed;
    static volatile int invalid;
    static int salt;
    static final class Cell {
        final int value;
        Cell(int value) { this.value = value; }
    }
    static class Base {
        final int id;
        final int owner;
        Base(int id, int owner) { this.id = id; this.owner = owner; }
        protected void finalize() {
            if (owner != salt || id < 0 || id >= seen.length || seen[id] != 0) invalid = 1;
            else seen[id] = 1;
            completed++;
        }
    }
    static final class Finalizable extends Base {
        Finalizable(int id, int owner) { super(id, owner); }
    }
    static void check(boolean ok) {
        if (!ok) throw new IllegalStateException("GC callback mismatch: completed="+completed+" invalid="+invalid);
    }
    static void makeRound(int round) {
        pending = new Finalizable[N];
        strong = new Object[N];
        weak = new WeakReference[N];
        for (int i=0; i<N; ++i) {
            pending[i] = new Finalizable(round*N+i,salt);
            strong[i] = new Cell(salt+i);
            weak[i] = new WeakReference(strong[i]);
        }
    }
    static void checkStrong() {
        for (int i=0; i<N; ++i) check(weak[i].get() == strong[i]);
    }
    static boolean cleared() {
        for (int i=0; i<N; ++i) if (weak[i].get() != null) return false;
        return true;
    }
    static void awaitRound(int expected) throws Exception {
        for (int retry=0; retry<40; ++retry) {
            // Let the real periodic worker collect, not a synchronous host mock.
            if (retry % 4 == 0) System.gc();
            Thread.sleep(250);
            check(invalid == 0 && completed <= expected);
            if (completed == expected && cleared()) return;
        }
        throw new IllegalStateException("callback timeout: completed="+completed+" expected="+expected);
    }
    public static void main(String[] args) throws Exception {
        salt = args[0].charAt(0)*100000;
        live = new Object[LIVE];
        for (int i=0; i<LIVE; ++i) live[i] = new Cell(salt+i);
        long digest=0;
        for (int round=0; round<ROUNDS; ++round) {
            makeRound(round);
            Thread.sleep(400);
            checkStrong();
            check(completed == round*N && invalid == 0);
            pending = null;
            strong = null;
            awaitRound((round+1)*N);
            weak = null;
            for (int i=0;i<LIVE;++i) {
                int value=((Cell)live[i]).value;
                check(value == salt+i);
                digest += value-salt;
            }
        }
        Thread.sleep(500);
        check(completed == N*ROUNDS && invalid == 0);
        for (int i=0; i<seen.length; ++i) check(seen[i] == 1);
        FileOutputStream out = new FileOutputStream(args[1]+"/gc-index.txt");
        out.write(("PASS "+completed+" "+digest+"\n").getBytes()); out.close();
    }
}
