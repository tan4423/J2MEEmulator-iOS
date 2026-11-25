/* SPDX-License-Identifier: MIT */
package com.sun.cldc.i18n.j2me;

import com.sun.cldc.i18n.StreamReader;
import java.io.IOException;
import java.io.InputStream;
import java.io.Reader;
import java.io.UnsupportedEncodingException;

/** UTF-8 decoder with resumable input state and short reads on live streams. */
public final class UTF_8_Reader extends StreamReader {
    private int pendingByte = -1;
    private int pendingLowSurrogate = -1;
    private int needed, value, minimum;
    private IOException pendingError;

    private void clearState() {
        pendingByte = pendingLowSurrogate = -1;
        needed = value = minimum = 0;
        pendingError = null;
    }

    public Reader open(InputStream input, String encoding) throws UnsupportedEncodingException {
        if (input == null) throw new NullPointerException();
        clearState();
        return super.open(input, encoding);
    }

    private void ensureOpen() throws IOException {
        if (in == null) throw new IOException("Stream closed");
    }

    public boolean ready() {
        return in != null && (pendingLowSurrogate >= 0 || pendingError != null ||
                (pendingByte >= 0 && pendingByte < 128) || super.ready());
    }

    public int read() throws IOException {
        ensureOpen();
        if (pendingError != null) {
            IOException error = pendingError;
            pendingError = null;
            throw error;
        }
        if (pendingLowSurrogate >= 0) {
            int low = pendingLowSurrogate;
            pendingLowSurrogate = -1;
            return low;
        }
        int cp = readCodePoint();
        if (cp <= 0xffff) return cp;
        int supplementary = cp - 0x10000;
        pendingLowSurrogate = 0xdc00 | (supplementary & 0x3ff);
        return 0xd800 | (supplementary >>> 10);
    }

    public int read(char[] output, int offset, int length) throws IOException {
        ensureOpen();
        if (output == null) throw new NullPointerException();
        if (offset < 0 || length < 0 || offset > output.length - length)
            throw new IndexOutOfBoundsException();
        if (length == 0) return 0;
        int count = 0;
        while (count < length) {
            // A live TCP peer may send a short line and wait for a reply.
            // Never fill the whole caller buffer by blocking after progress.
            if (count > 0 && !ready()) break;
            int ch;
            try { ch = read(); }
            catch (IOException error) {
                if (count == 0) throw error;
                pendingError = error; // deliver already decoded chars first
                break;
            }
            if (ch < 0) return count == 0 ? -1 : count;
            output[offset + count++] = (char)ch;
        }
        return count;
    }

    private static int continuationCount(int first) {
        if (first < 0x80) return 0;
        if (first >= 0xc2 && first <= 0xdf) return 1;
        if (first >= 0xe0 && first <= 0xef) return 2;
        if (first >= 0xf0 && first <= 0xf4) return 3;
        return -1;
    }

    private static int initialValue(int first, int n) {
        return first & (n == 0 ? 0x7f : n == 1 ? 0x1f : n == 2 ? 0x0f : 0x07);
    }

    private static int minValue(int n) {
        return n == 1 ? 0x80 : n == 2 ? 0x800 : n == 3 ? 0x10000 : 0;
    }

    private static boolean validCodePoint(int cp, int min) {
        return cp >= min && cp <= 0x10ffff && (cp < 0xd800 || cp > 0xdfff);
    }

    private int readCodePoint() throws IOException {
        if (needed == 0) {
            int first = nextByte();
            if (first < 0) return -1;
            int n = continuationCount(first);
            if (n < 0) return 0xfffd;
            if (n == 0) return first;
            needed = n;
            value = initialValue(first, n);
            minimum = minValue(n);
        }
        // Keep the partial sequence in fields: a SocketTimeoutException
        // or other retryable IOException must not discard consumed bytes.
        while (needed > 0) {
            int next = nextByte();
            if (next < 0 || (next & 0xc0) != 0x80) {
                needed = 0;
                if (next >= 0) pendingByte = next;
                return 0xfffd;
            }
            value = (value << 6) | (next & 0x3f);
            --needed;
        }
        return validCodePoint(value, minimum) ? value : 0xfffd;
    }

    private int nextByte() throws IOException {
        if (pendingByte >= 0) {
            int b = pendingByte;
            pendingByte = -1;
            return b;
        }
        return in.read();
    }

    public int sizeOf(byte[] input, int offset, int length) {
        if (input == null) throw new NullPointerException();
        if (offset < 0 || length < 0 || offset > input.length - length)
            throw new IndexOutOfBoundsException();
        int count = 0, end = offset + length;
        while (offset < end) {
            int first = input[offset++] & 0xff;
            int n = continuationCount(first);
            if (n < 0) { count++; continue; }
            int cp = initialValue(first, n), consumed = 0;
            while (consumed < n && offset < end && (input[offset] & 0xc0) == 0x80) {
                cp = (cp << 6) | (input[offset++] & 0x3f);
                consumed++;
            }
            count += consumed == n && validCodePoint(cp, minValue(n)) && cp > 0xffff ? 2 : 1;
        }
        return count;
    }

    public boolean markSupported() { return false; }
    public void mark(int limit) throws IOException { throw new IOException("mark not supported"); }
    public void reset() throws IOException { throw new IOException("reset not supported"); }
    public void close() throws IOException {
        InputStream input = in;
        in = null;
        clearState();
        if (input != null) input.close();
    }
}
