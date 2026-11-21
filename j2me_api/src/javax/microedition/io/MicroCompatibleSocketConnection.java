package javax.microedition.io;

import java.io.DataInputStream;
import java.io.DataOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.InetSocketAddress;
import java.net.Socket;

/**
 * Java ME socket wrapper matching MicroEmulator 2.0.4's implementation:
 * use java.net.Socket streams, not the CLDC Protocol's read-to-full-buffer
 * loop. TCP InputStream.read(byte[], ...) may return fewer bytes than asked.
 * miniJVM's Socket delegates the actual TCP work to SocketNative on iOS.
 */
final class MicroCompatibleSocketConnection implements SocketConnection {
    private final Socket socket;
    private boolean tcpNoDelay = true;

    MicroCompatibleSocketConnection(String host, int port) throws IOException {
        socket = new Socket(host, port);
    }

    public InputStream openInputStream() throws IOException {
        return socket.getInputStream();
    }

    public DataInputStream openDataInputStream() throws IOException {
        return new DataInputStream(openInputStream());
    }

    public OutputStream openOutputStream() throws IOException {
        return socket.getOutputStream();
    }

    public DataOutputStream openDataOutputStream() throws IOException {
        return new DataOutputStream(openOutputStream());
    }

    public void close() throws IOException {
        socket.close();
    }

    public void setSocketOption(byte option, int value) throws IOException {
        switch (option) {
            case DELAY:
                tcpNoDelay = value != 0;
                socket.setTcpNoDelay(tcpNoDelay);
                return;
            case LINGER:
                socket.setSoLinger(value != 0, value);
                return;
            case KEEPALIVE:
                socket.setKeepAlive(value != 0);
                return;
            case RCVBUF:
                if (value <= 0) throw new IllegalArgumentException("RCVBUF");
                socket.setReceiveBufferSize(value);
                return;
            case SNDBUF:
                if (value <= 0) throw new IllegalArgumentException("SNDBUF");
                socket.setSendBufferSize(value);
                return;
            default:
                throw new IllegalArgumentException("Unknown socket option " + option);
        }
    }

    public int getSocketOption(byte option) throws IOException {
        switch (option) {
            case DELAY: return tcpNoDelay ? 1 : 0;
            case LINGER: return socket.getSoLinger();
            case KEEPALIVE: return socket.getKeepAlive() ? 1 : 0;
            case RCVBUF: return socket.getReceiveBufferSize();
            case SNDBUF: return socket.getSendBufferSize();
            default: throw new IllegalArgumentException("Unknown socket option " + option);
        }
    }

    private static InetSocketAddress address(java.net.SocketAddress address) throws IOException {
        if (!(address instanceof InetSocketAddress)) {
            throw new IOException("Socket address unavailable");
        }
        return (InetSocketAddress) address;
    }

    public String getAddress() throws IOException {
        return address(socket.getRemoteSocketAddress()).getAddress().getHostAddress();
    }

    public int getPort() throws IOException {
        return address(socket.getRemoteSocketAddress()).getPort();
    }

    public String getLocalAddress() throws IOException {
        return address(socket.getLocalSocketAddress()).getAddress().getHostAddress();
    }

    public int getLocalPort() throws IOException {
        return address(socket.getLocalSocketAddress()).getPort();
    }
}
