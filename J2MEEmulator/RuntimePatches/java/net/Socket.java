/* SPDX-License-Identifier: MIT; based on miniJVM java.net.Socket by Gust.
 * Preserve miniJVM SocketImpl ABI. Network operations use the real native socket.
 */
package java.net;

import org.mini.net.SocketNative;

import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;

/**
 * @author Gust
 */
public class Socket extends SocketImpl {

    boolean isConnected = false;
    private boolean inputShutdown, outputShutdown;
    private static native int jarboxConnect0(byte[] handle, byte[] host, byte[] port, int protocol, int timeout);
    private static native int jarboxShutdown0(byte[] handle, int direction);
    private static native int jarboxRead0(byte[] handle, byte[] data, int offset, int length);

    protected Socket(byte[] sockfd) throws IOException {
        fd = sockfd;
        isConnected = true;
    }

    public Socket() throws IOException {
        super();
    }

    public Socket(InetAddress address, int port) throws IOException {
        this(address.getHostAddress(), port);
    }

    public Socket(String host, int port) throws UnknownHostException, IOException {
        this();
        connect(host, port);
    }

    InputStream inputStream;
    OutputStream outputStream;

    private byte[] requireConnected() throws IOException {
        if (fd == null || !isConnected) throw new IOException("socket not connected");
        return fd;
    }

    private static void checkRange(byte[] b, int off, int len) {
        if (b == null) throw new NullPointerException();
        if (off < 0 || len < 0 || off > b.length || len > b.length - off)
            throw new IndexOutOfBoundsException();
    }

    public InputStream getInputStream() throws IOException {
        requireConnected();
        if (inputShutdown) throw new IOException("socket input shutdown");
        if (inputStream != null) return inputStream;
        inputStream = new InputStream() {
            private final byte[] one = new byte[1];
            @Override public int read() throws IOException {
                int n = read(one, 0, 1);
                return n < 0 ? -1 : one[0] & 255;
            }
            @Override public int read(byte[] b, int offset, int len) throws IOException {
                checkRange(b, offset, len);
                if (len == 0) return 0;
                byte[] handle = requireConnected();
                if (inputShutdown) return -1;
                int n = jarboxRead0(handle, b, offset, len);
                if (n == -2) throw new SocketTimeoutException("read timeout");
                if (n < -1 || n == 0) throw new IOException("socket read error");
                return n;
            }
            @Override public int available() throws IOException {
                byte[] handle = requireConnected();
                return inputShutdown ? 0 : SocketNative.available0(handle);
            }
            @Override public void close() throws IOException { Socket.this.close(); }
        };
        return inputStream;
    }

    public OutputStream getOutputStream() throws IOException {
        requireConnected();
        if (outputShutdown) throw new IOException("socket output shutdown");
        if (outputStream != null) return outputStream;
        outputStream = new OutputStream() {
            @Override public void write(int b) throws IOException {
                byte[] one = {(byte)b};
                write(one, 0, 1);
            }
            @Override public void write(byte[] b, int offset, int len) throws IOException {
                checkRange(b, offset, len);
                byte[] handle = requireConnected();
                if (outputShutdown) throw new IOException("socket output shutdown");
                int sent = 0;
                while (sent < len) {
                    int n = SocketNative.write(handle, b, offset + sent, len - sent);
                    if (n <= 0 || n > len - sent) throw new IOException("socket write error");
                    sent += n;
                }
            }
            @Override public void close() throws IOException { Socket.this.close(); }
        };
        return outputStream;
    }

    private void connect(String host, int port) throws IOException {
        connectInternal(host, port, 0);
    }

    private void connectInternal(String host, int port, int timeout) throws IOException {
        if (timeout < 0 || port < 0 || port > 65535 || host == null)
            throw new IllegalArgumentException("invalid socket endpoint or timeout");
        if (fd == null || isConnected) throw new IOException("socket closed or already connected");
        int ret = jarboxConnect0(fd, SocketNative.toCStyle(host),
                SocketNative.toCStyle(Integer.toString(port)), SocketNative.NET_PROTO_TCP, timeout);
        if (ret == -2) throw new SocketTimeoutException("connect timeout");
        if (ret < 0) throw new IOException("socket connect error");
        this.host = host;
        this.port = port;
        isConnected = true;
    }

    public void connect(SocketAddress endpoint) throws IOException { connect(endpoint, 0); }

    public void connect(SocketAddress endpoint, int timeout) throws IOException {
        if (!(endpoint instanceof InetSocketAddress) || timeout < 0)
            throw new IllegalArgumentException("invalid socket endpoint or timeout");
        InetSocketAddress address = (InetSocketAddress)endpoint;
        if (address.getAddress() == null) throw new UnknownHostException();
        connectInternal(address.getAddress().getHostName(), address.getPort(), timeout);
    }

    public void shutdownInput() throws IOException {
        byte[] handle = requireConnected();
        if (inputShutdown || jarboxShutdown0(handle, 0) != 0)
            throw new IOException("socket input shutdown failed");
        inputShutdown = true;
    }

    public void shutdownOutput() throws IOException {
        byte[] handle = requireConnected();
        if (outputShutdown || jarboxShutdown0(handle, 1) != 0)
            throw new IOException("socket output shutdown failed");
        outputShutdown = true;
    }

    public void setNonBlock(boolean on) throws SocketException {
        if (fd != null) {
            SocketNative.setOption0(fd, SocketNative.SO_NONBLOCK, on ? 1 : 0, 0);
        }
    }

    public void setTcpNoDelay(boolean on) throws SocketException {
        if (fd == null || SocketNative.setOption0(fd, 7, on ? 1 : 0, 0) != 0)
            throw new SocketException("TCP_NODELAY failed");
    }

    public boolean getTcpNoDelay() throws SocketException {
        int value = fd == null ? -1 : SocketNative.getOption0(fd, 7);
        if (value < 0) throw new SocketException("TCP_NODELAY unavailable");
        return value != 0;
    }

    public void setSoLinger(boolean on, int linger) {
        SocketNative.setOption0(fd, SocketNative.SO_LINGER, on ? 1 : 0, linger);
    }

    public int getSoLinger() {
        return SocketNative.getOption0(fd, SocketNative.SO_LINGER);
    }

    public void setSoTimeout(int millSecond) {
        if (millSecond < 0) throw new IllegalArgumentException("negative timeout");
        if (fd == null || SocketNative.setOption0(fd, SocketNative.SO_TIMEOUT, millSecond, 0) != 0)
            throw new IllegalStateException("socket timeout unavailable");
    }

    public int getSoTimeout() {
        return SocketNative.getOption0(fd, SocketNative.SO_TIMEOUT);
    }

    public void setSendBufferSize(int size) {
        SocketNative.setOption0(fd, SocketNative.SO_SNDBUF, size, 0);
    }

    public int getSendBufferSize() {
        return SocketNative.getOption0(fd, SocketNative.SO_SNDBUF);
    }

    public void setReceiveBufferSize(int size) {
        SocketNative.setOption0(fd, SocketNative.SO_RCVBUF, size, 0);
    }

    public int getReceiveBufferSize() {
        return SocketNative.getOption0(fd, SocketNative.SO_RCVBUF);
    }

    public void setKeepAlive(boolean on) {
        SocketNative.setOption0(fd, SocketNative.SO_KEEPALIVE, on ? 1 : 0, 0);
    }

    public boolean getKeepAlive() {
        return SocketNative.getOption0(fd, SocketNative.SO_KEEPALIVE) == 0 ? false : true;
    }

    public SocketAddress getRemoteSocketAddress() {
        String s = SocketNative.getSockAddr(fd, 0);
        if (s != null) {
            int index = s.lastIndexOf(':');
            if (index >= 0) {
                host = s.substring(0, index);
                port = Integer.parseInt(s.substring(index + 1));
            }
        }
        InetSocketAddress isa = new InetSocketAddress(host, port);
        return isa;
    }

    public SocketAddress getLocalSocketAddress() {
        String s = SocketNative.getSockAddr(fd, 1);
        if (s != null) {
            int index = s.lastIndexOf(':');
            if (index >= 0) {
                localHost = s.substring(0, index);
                localport = Integer.parseInt(s.substring(index + 1));
            }
        }
        InetSocketAddress isa = new InetSocketAddress(localHost, localport);
        return isa;
    }

    public String toString() {
        return getRemoteSocketAddress() + "/" + getLocalSocketAddress();
    }
}
