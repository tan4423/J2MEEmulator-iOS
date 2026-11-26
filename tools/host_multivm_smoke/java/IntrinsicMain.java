import java.io.FileOutputStream;

/** Headless differential: same workload, different owner-local static state. */
public final class IntrinsicMain {
    private static int[] map;
    private static int width;
    // Exact shape of the candidate; do not add checks or alter the handler.
    static int lookup(int x, int y) {
        try { return map[y * width + x]; }
        catch (Exception e) { return 1000; }
    }
    private static void check(boolean ok) {
        if (!ok) throw new IllegalStateException("intrinsic differential mismatch");
    }
    private static int badChar(String text, int index) {
        try { return text.charAt(index); }
        catch (IndexOutOfBoundsException e) { return -1; }
    }
    public static void main(String[] args) throws Exception {
        int salt = args[0].charAt(0) * 100000;
        long digest = 0;
        int initial = lookup(0, 0); // null map: original handler must run
        check(initial == 1000);
        for (int round = 0; round < 8; round++) {
            width = 17 + round;
            int[] expected = new int[width * 31];
            for (int i = 0; i < expected.length; i++) expected[i] = salt + round * 1000 + i;
            map = expected;
            for (int i = 0; i < 20000; i++) {
                int x = i % width, y = (i / width) % 31;
                int actual = lookup(x, y);
                check(actual == expected[y * width + x]);
                digest += actual - salt;
            }
            check(lookup(-1, 0) == 1000);
            check(lookup(0, 31) == 1000);
            map = null;
            check(lookup(0, 0) == 1000);
            char[] chars = new char[8192];
            for (int i = 0; i < chars.length; i++) chars[i] = (char)(round * 8192 + i);
            String text = new String(chars);
            for (int i = 0; i < chars.length; i++) {
                int actual = text.charAt(i);
                check(actual == chars[i]);
                digest += actual;
            }
            String slice = text.substring(7, chars.length - 3);
            for (int i = 0; i < slice.length(); i++) {
                int actual = slice.charAt(i);
                check(actual == chars[i + 7]);
                digest += actual;
            }
            // Include baseline native/Java error behavior in the digest.
            digest += badChar(text, -1) + badChar(text, text.length());
            // Allocate with references live, request and allow real worker GC.
            byte[][] pressure = new byte[128][];
            for (int i = 0; i < pressure.length; i++) {
                pressure[i] = new byte[4096]; pressure[i][0] = (byte)i;
            }
            System.gc(); Thread.sleep(300);
            check(pressure[127][0] == 127 && slice.charAt(0) == chars[7]);
        }
        FileOutputStream out = new FileOutputStream(args[1] + "/intrinsic.txt");
        out.write(("PASS " + digest + "\n").getBytes()); out.close();
    }
}
