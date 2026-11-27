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
    // No referent is inspected from the long-lived main stack. MiniJVM's
    // conservative reference lanes can retain a value after get() returns.
    // The producer and each observer retire before the next GC request.
    static volatile int clearedCount, produced;
    static void produce(final int round) throws Exception {
        produced=0;
        Thread producer = new Thread() {
            public void run() {
                makeRound(round);
                try { Thread.sleep(400); }
                catch (InterruptedException ex) { invalid=1; }
                checkStrong();
                check(completed == round*N && invalid == 0);
                pending=null; strong=null;
                produced=1;
            }
        };
        producer.start(); producer.join();
        check(produced == 1 && invalid == 0);
    }
    static int countCleared() throws Exception {
        clearedCount=-1;
        Thread observer=new Thread() {
            public void run() {
                int count=0;
                for (int i=0; i<N; ++i) if (weak[i].get() == null) ++count;
                clearedCount=count;
            }
        };
        observer.start(); observer.join();
        check(clearedCount>=0);
        return clearedCount;
    }
    static void awaitRound(int expected) throws Exception {
        int count=0;
        for (int retry=0; retry<40; ++retry) {
            if (retry % 4 == 0) System.gc();
            Thread.sleep(250);
            check(invalid == 0 && completed <= expected);
            if (retry % 4 == 3 && completed == expected) {
                count=countCleared();
                if(count==N)return;
            }
        }
        throw new IllegalStateException("callback timeout: completed="+completed+" expected="+expected+" cleared="+count);
    }
    public static void main(String[] args) throws Exception {
        salt = args[0].charAt(0)*100000;
        live = new Object[LIVE];
        for (int i=0; i<LIVE; ++i) live[i] = new Cell(salt+i);
        long digest=0;
        for (int round=0; round<ROUNDS; ++round) {
            produce(round);
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
