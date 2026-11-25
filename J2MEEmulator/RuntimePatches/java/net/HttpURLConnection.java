package java.net;

import javax.microedition.io.Connection;
import javax.microedition.io.Connector;
import javax.microedition.io.HttpConnection;
import java.io.*;
import java.util.*;

public abstract class HttpURLConnection extends URLConnection {
    protected String HTTP_GET = "GET";
    protected String HTTP_POST = "POST";
    protected String HTTP_HEAD = "HEAD";
    protected String HTTP_PUT = "PUT";
    protected String HTTP_DELETE = "DELETE";
    protected String HTTP_TRACE = "TRACE";
    protected String HTTP_OPTIONS = "OPTIONS";

    String[] methods = {
            HTTP_GET,
            HTTP_POST,
            HTTP_HEAD,
            HTTP_PUT,
            HTTP_DELETE,
            HTTP_TRACE,
            HTTP_OPTIONS
    };
    private static final String HKEY_CONTENT_LENGTH = "content-length";

    protected javax.microedition.io.HttpConnection connection;
    protected Map<String, List<String>> outHeader = new HashMap<>();
    protected ByteArrayOutputStream outData;

    protected int status;
    protected Map<String, List<String>> rcvHeader = new HashMap<>();
    protected byte[] rcvData;

    String method = HTTP_GET;

    protected HttpURLConnection(URL url) {
        super(url);
    }

    // The scope belongs to the current OS thread and JVM, not a global
    // socket option. Pooled sockets get the current request's read limit.
    private static native int jarboxHttpBegin(int connectMs, int readMs);
    private static native int jarboxHttpEnd();
    private static native int jarboxHttpTimedOut();

    @Override
    public synchronized void connect() throws IOException {
        if (rcvData != null) return;
        if (jarboxHttpBegin(getConnectTimeout(), getReadTimeout()) != 0)
            throw new IOException("HTTP timeout scope unavailable");
        boolean complete = false;
        try {
            connectInternal();
            complete = true;
        } finally {
            int timeout;
            try {
                if (!complete || jarboxHttpTimedOut() != 0) {
                    rcvData = null;
                    rcvHeader.clear();
                    HttpConnection failed = connection;
                    connection = null;
                    if (failed != null) {
                        try { failed.close(); } catch (Exception ignored) {}
                    }
                }
            } finally {
                // Keep a failed scope active through GCF cleanup: it may
                // attempt to send/finish a request while closing.
                timeout = jarboxHttpEnd();
            }
            if (timeout != 0)
                throw new SocketTimeoutException(timeout == 1 ? "HTTP connect timeout" : "HTTP read timeout");
        }
    }

    private void connectInternal() throws IOException {
        if (rcvData != null) return;

        String urlStr = url.toString();
        // Full URL including query identifies the resource. Do not cache
        // POST or requests with caller-supplied headers.
        boolean cacheable = useCaches && method.equals(HTTP_GET) && outHeader.isEmpty();
        CachedFile ba = cacheable ? caches.get(urlStr) : null;
        if (ba != null && !ba.isExpired()) {
            if (useCaches) {  //cache hit
                rcvData = (byte[]) ba.resource;
                return;
            }
        } else if (cacheable) {
            caches.remove(urlStr);
        }
        //request
        if (connection == null) {
            Connection con = Connector.open(url.toString());
            if (!(con instanceof HttpConnection)) {
                if (con != null) con.close();
                throw new IOException("not an HTTP connection");
            }
            if (con instanceof HttpConnection) {
                connection = (HttpConnection) con;
                if (method.equals(HTTP_POST)) {
                    connection.setRequestMethod(HttpConnection.POST);
                    byte[] data = outData == null ? new byte[0] : outData.toByteArray();
                    for (String k : outHeader.keySet()) {
                        List<String> vals = outHeader.get(k);
                        StringBuilder sb = new StringBuilder();
                        for (String v : vals) {
                            sb.append(v).append(',');
                        }
                        if (sb.length() > 0) {
                            sb.deleteCharAt(sb.length() - 1);
                        }
                        connection.setRequestProperty(k, sb.toString());
                    }
                    connection.setRequestProperty("Content-Length", String.valueOf(data.length));
                    DataOutputStream output = connection.openDataOutputStream();
                    try { output.write(data); output.flush(); }
                    finally { output.close(); }
                } else {
                    connection.setRequestMethod(HttpConnection.GET);
                    for (String k : outHeader.keySet()) {
                        List<String> vals = outHeader.get(k);
                        StringBuilder sb = new StringBuilder();
                        for (String v : vals) {
                            if (sb.length() > 0) sb.append(',');
                            sb.append(v);
                        }
                        connection.setRequestProperty(k, sb.toString());
                    }
                }
                status = connection.getResponseCode();
                if (status != HttpConnection.HTTP_OK) {
                    throw new IOException("Http status: " + status);
                }
                for (int i = 0; true; i++) {
                    String k = connection.getHeaderFieldKey(i);
                    if (k == null) break;
                    String v = connection.getHeaderField(k);
                    List<String> list = new ArrayList<>();
                    list.add(v);
                    rcvHeader.put(k.toLowerCase(), list);
                }
                ByteArrayOutputStream baos = new ByteArrayOutputStream();
                InputStream is = connection.openDataInputStream();
                byte[] buf = new byte[1024];
                try {
                    while (true) {
                        int len = is.read(buf);
                        if (jarboxHttpTimedOut() != 0)
                            throw new SocketTimeoutException("HTTP read timeout");
                        if (len < 0) break;
                        if (len == 0) {
                            int one = is.read();
                            if (one < 0) break;
                            baos.write(one);
                        } else baos.write(buf, 0, len);
                    }
                } finally {
                    is.close();
                }
                if (jarboxHttpTimedOut() != 0)
                    throw new SocketTimeoutException("HTTP read timeout");
                rcvData = baos.toByteArray();
                long exp = connection.getExpiration();
                long cur = System.currentTimeMillis();
                if (cacheable && cur < exp && jarboxHttpTimedOut() == 0) {
                    CachedFile res = new CachedFile(rcvData, connection.getExpiration());
                    caches.put(urlStr, res);
                }
            }
        }
    }


    @Override
    public InputStream getInputStream() throws IOException {
        connect();
        return new ByteArrayInputStream(rcvData);
    }

    @Override
    public OutputStream getOutputStream() throws IOException {
        if (outData == null) {
            outData = new ByteArrayOutputStream();
        }
        return outData;
    }

    @Override
    public int getContentLength() {
        return getHeaderFieldInt(HKEY_CONTENT_LENGTH, -1);
    }

    @Override
    public long getContentLengthLong() {
        return getHeaderFieldLong(HKEY_CONTENT_LENGTH, -1l);
    }

    @Override
    public Map<String, List<String>> getHeaderFields() {
        return (rcvHeader);
    }

    public void setRequestProperty(String key, String value) {
        List<String> list = new ArrayList<>();
        list.add(value);
        outHeader.put(key.toLowerCase(), list);
    }

    public void addRequestProperty(String key, String value) {
        List<String> list = outHeader.get(key.toLowerCase());
        if (list == null) {
            list = new ArrayList<>();
            outHeader.put(key.toLowerCase(), list);
        }
        list.add(value);
    }

    public String getRequestProperty(String key) {
        List<String> list = outHeader.get(key.toLowerCase());
        if (list != null && list.size() > 0) {
            return list.get(0);
        } else {
            return null;
        }
    }

    public Map<String, List<String>> getRequestProperties() {
        return outHeader;
    }

    public void setRequestMethod(String method) {
        for (String m : methods) {
            if (m.equals(method)) {
                this.method = method;
                return;
            }
        }
        throw new IllegalArgumentException("method not support");
    }

    public abstract void disconnect();
}
