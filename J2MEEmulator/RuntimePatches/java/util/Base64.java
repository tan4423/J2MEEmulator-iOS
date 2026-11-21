/* SPDX-License-Identifier: MIT */
package java.util;

/**
 * Small, self-contained Java 8 Base64 compatibility layer for miniJVM/CLDC.
 * Supports byte-array/String encoding and decoding in Basic, URL and MIME
 * modes. ByteBuffer and stream wrapper APIs are deliberately not provided.
 */
public final class Base64 {
    private static final String BASIC =
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    private static final String URL =
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";

    private Base64() { }

    public static Encoder getEncoder() { return new Encoder(false, true, 0, null); }
    public static Encoder getUrlEncoder() { return new Encoder(true, true, 0, null); }
    public static Decoder getDecoder() { return new Decoder(false, false); }
    public static Decoder getUrlDecoder() { return new Decoder(true, false); }
    public static Decoder getMimeDecoder() { return new Decoder(false, true); }
    public static Encoder getMimeEncoder() {
        return new Encoder(false, true, 76, new byte[] { 13, 10 });
    }

    public static Encoder getMimeEncoder(int lineLength, byte[] lineSeparator) {
        if (lineSeparator == null) throw new NullPointerException("lineSeparator");
        for (int i = 0; i < lineSeparator.length; i++) {
            int c = lineSeparator[i] & 255;
            if (c == '=' || alphabetValue(c, false) >= 0) {
                throw new IllegalArgumentException("Base64 character in line separator");
            }
        }
        return new Encoder(false, true, lineLength > 0 ? (lineLength / 4) * 4 : 0,
                           copySeparator(lineSeparator));
    }

    private static byte[] copySeparator(byte[] src) {
        byte[] copy = new byte[src.length];
        System.arraycopy(src, 0, copy, 0, src.length);
        return copy;
    }

    private static int alphabetValue(int c, boolean url) {
        if (c >= 'A' && c <= 'Z') return c - 'A';
        if (c >= 'a' && c <= 'z') return c - 'a' + 26;
        if (c >= '0' && c <= '9') return c - '0' + 52;
        if (c == (url ? '-' : '+')) return 62;
        if (c == (url ? '_' : '/')) return 63;
        return -1;
    }

    public static final class Encoder {
        private final boolean url;
        private final boolean padding;
        private final int lineLength;
        private final byte[] separator;

        private Encoder(boolean url, boolean padding, int lineLength, byte[] separator) {
            this.url = url;
            this.padding = padding;
            this.lineLength = lineLength;
            this.separator = separator;
        }

        public Encoder withoutPadding() {
            return padding ? new Encoder(url, false, lineLength, separator) : this;
        }

        public byte[] encode(byte[] src) {
            if (src == null) throw new NullPointerException("src");
            long units = (src.length + 2L) / 3L;
            long chars = units * 4L;
            if (!padding && src.length % 3 != 0) chars -= 3 - src.length % 3;
            long breaks = lineLength > 0 && chars > 0 ? (chars - 1L) / lineLength : 0;
            long total = chars + breaks * (separator == null ? 0 : separator.length);
            if (total > Integer.MAX_VALUE) throw new OutOfMemoryError("Base64 output too large");
            byte[] dst = new byte[(int) total];
            int at = 0, col = 0;
            String letters = url ? URL : BASIC;
            for (int i = 0; i < src.length; i += 3) {
                if (lineLength > 0 && col >= lineLength) {
                    System.arraycopy(separator, 0, dst, at, separator.length);
                    at += separator.length;
                    col = 0;
                }
                int remain = src.length - i;
                int b0 = src[i] & 255;
                int b1 = remain > 1 ? src[i + 1] & 255 : 0;
                int b2 = remain > 2 ? src[i + 2] & 255 : 0;
                dst[at++] = (byte) letters.charAt(b0 >>> 2);
                dst[at++] = (byte) letters.charAt(((b0 & 3) << 4) | (b1 >>> 4));
                if (remain > 1) dst[at++] = (byte) letters.charAt(((b1 & 15) << 2) | (b2 >>> 6));
                else if (padding) dst[at++] = (byte) '=';
                if (remain > 2) dst[at++] = (byte) letters.charAt(b2 & 63);
                else if (padding) dst[at++] = (byte) '=';
                col += padding || remain >= 3 ? 4 : remain + 1;
            }
            return dst;
        }

        public int encode(byte[] src, byte[] dst) {
            if (dst == null) throw new NullPointerException("dst");
            byte[] encoded = encode(src);
            if (dst.length < encoded.length) throw new IllegalArgumentException("Output buffer too small");
            System.arraycopy(encoded, 0, dst, 0, encoded.length);
            return encoded.length;
        }

        public String encodeToString(byte[] src) {
            byte[] encoded = encode(src);
            char[] chars = new char[encoded.length];
            for (int i = 0; i < encoded.length; i++) chars[i] = (char) (encoded[i] & 255);
            return new String(chars);
        }
    }

    public static final class Decoder {
        private final boolean url;
        private final boolean mime;

        private Decoder(boolean url, boolean mime) {
            this.url = url;
            this.mime = mime;
        }

        public byte[] decode(String src) {
            if (src == null) throw new NullPointerException("src");
            byte[] data = new byte[src.length()];
            for (int i = 0; i < data.length; i++) {
                char c = src.charAt(i);
                data[i] = (byte) (c <= 255 ? c : '?');
            }
            return decode(data);
        }

        public byte[] decode(byte[] src) {
            if (src == null) throw new NullPointerException("src");
            byte[] cleaned = new byte[src.length];
            int n = 0;
            for (int i = 0; i < src.length; i++) {
                int c = src[i] & 255;
                if (c == '=' || alphabetValue(c, url) >= 0) {
                    cleaned[n++] = (byte) c;
                } else if (!mime) {
                    throw new IllegalArgumentException("Illegal Base64 character");
                }
            }
            int pad = 0;
            while (pad < n && cleaned[n - pad - 1] == '=') pad++;
            int dataLength = n - pad;
            if (pad > 2 || (pad != 0 && (n % 4 != 0 || dataLength % 4 != (pad == 1 ? 3 : 2))) ||
                (pad == 0 && dataLength % 4 == 1)) {
                throw new IllegalArgumentException("Invalid Base64 padding or length");
            }
            for (int i = 0; i < dataLength; i++) {
                if (cleaned[i] == '=') throw new IllegalArgumentException("Unexpected Base64 padding");
            }
            long outputSize = (long) (dataLength / 4) * 3 +
                              (dataLength % 4 == 2 ? 1 : dataLength % 4 == 3 ? 2 : 0);
            if (outputSize > Integer.MAX_VALUE) throw new OutOfMemoryError("Base64 output too large");
            byte[] dst = new byte[(int) outputSize];
            int bits = 0, count = 0, at = 0;
            for (int i = 0; i < dataLength; i++) {
                bits = (bits << 6) | alphabetValue(cleaned[i] & 255, url);
                count++;
                if (count == 4) {
                    dst[at++] = (byte) (bits >>> 16);
                    dst[at++] = (byte) (bits >>> 8);
                    dst[at++] = (byte) bits;
                    bits = 0;
                    count = 0;
                }
            }
            if (count == 2) dst[at++] = (byte) (bits >>> 4);
            else if (count == 3) {
                dst[at++] = (byte) (bits >>> 10);
                dst[at++] = (byte) (bits >>> 2);
            }
            return dst;
        }

        public int decode(byte[] src, byte[] dst) {
            if (dst == null) throw new NullPointerException("dst");
            byte[] decoded = decode(src);
            if (dst.length < decoded.length) throw new IllegalArgumentException("Output buffer too small");
            System.arraycopy(decoded, 0, dst, 0, decoded.length);
            return decoded.length;
        }
    }
}
