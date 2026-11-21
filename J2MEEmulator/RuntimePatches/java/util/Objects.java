/* SPDX-License-Identifier: MIT */
package java.util;

/** Java 7/8 Objects compatibility without modern JDK or reflection dependencies. */
public final class Objects {
    private Objects() { }

    public static boolean equals(Object a, Object b) {
        return a == b || (a != null && a.equals(b));
    }

    public static boolean deepEquals(Object a, Object b) {
        if (a == b) return true;
        if (a == null || b == null) return false;
        if (a instanceof Object[] && b instanceof Object[]) {
            Object[] left = (Object[]) a, right = (Object[]) b;
            if (left.length != right.length) return false;
            for (int i = 0; i < left.length; i++) {
                if (!deepEquals(left[i], right[i])) return false;
            }
            return true;
        }
        if (a instanceof byte[] && b instanceof byte[]) {
            byte[] left = (byte[]) a, right = (byte[]) b;
            if (left.length != right.length) return false;
            for (int i = 0; i < left.length; i++) if (left[i] != right[i]) return false;
            return true;
        }
        if (a instanceof boolean[] && b instanceof boolean[]) {
            boolean[] left = (boolean[]) a, right = (boolean[]) b;
            if (left.length != right.length) return false;
            for (int i = 0; i < left.length; i++) if (left[i] != right[i]) return false;
            return true;
        }
        if (a instanceof char[] && b instanceof char[]) {
            char[] left = (char[]) a, right = (char[]) b;
            if (left.length != right.length) return false;
            for (int i = 0; i < left.length; i++) if (left[i] != right[i]) return false;
            return true;
        }
        if (a instanceof short[] && b instanceof short[]) {
            short[] left = (short[]) a, right = (short[]) b;
            if (left.length != right.length) return false;
            for (int i = 0; i < left.length; i++) if (left[i] != right[i]) return false;
            return true;
        }
        if (a instanceof int[] && b instanceof int[]) {
            int[] left = (int[]) a, right = (int[]) b;
            if (left.length != right.length) return false;
            for (int i = 0; i < left.length; i++) if (left[i] != right[i]) return false;
            return true;
        }
        if (a instanceof long[] && b instanceof long[]) {
            long[] left = (long[]) a, right = (long[]) b;
            if (left.length != right.length) return false;
            for (int i = 0; i < left.length; i++) if (left[i] != right[i]) return false;
            return true;
        }
        if (a instanceof float[] && b instanceof float[]) {
            float[] left = (float[]) a, right = (float[]) b;
            if (left.length != right.length) return false;
            for (int i = 0; i < left.length; i++) if (Float.floatToIntBits(left[i]) != Float.floatToIntBits(right[i])) return false;
            return true;
        }
        if (a instanceof double[] && b instanceof double[]) {
            double[] left = (double[]) a, right = (double[]) b;
            if (left.length != right.length) return false;
            for (int i = 0; i < left.length; i++) if (Double.doubleToLongBits(left[i]) != Double.doubleToLongBits(right[i])) return false;
            return true;
        }
        return a.equals(b);
    }

    public static int hashCode(Object obj) { return obj == null ? 0 : obj.hashCode(); }

    public static int hash(Object... values) {
        if (values == null) return 0;
        int result = 1;
        for (int i = 0; i < values.length; i++) result = 31 * result + hashCode(values[i]);
        return result;
    }

    public static String toString(Object obj) { return String.valueOf(obj); }
    public static String toString(Object obj, String nullDefault) {
        return obj == null ? nullDefault : obj.toString();
    }
    public static boolean isNull(Object obj) { return obj == null; }
    public static boolean nonNull(Object obj) { return obj != null; }

    public static <T> T requireNonNull(T obj) {
        if (obj == null) throw new NullPointerException();
        return obj;
    }
    public static <T> T requireNonNull(T obj, String message) {
        if (obj == null) throw new NullPointerException(message);
        return obj;
    }
    public static <T> int compare(T a, T b, Comparator<? super T> c) {
        return a == b ? 0 : c.compare(a, b);
    }
}
