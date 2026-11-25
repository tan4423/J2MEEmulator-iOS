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
    protected String cacheFilePath;
    protected String responseMessage;
    protected List<String> headerKeys = new ArrayList<>();
    protected List<String> headerValues = new ArrayList<>();
    private static final long MAX_REUSABLE_BODY = 256 * 1024L;

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
        if (cacheFilePath != null) return;
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
                    releaseResponseFile();
                    rcvHeader.clear();
                    headerKeys.clear();
                    headerValues.clear();
                    status = 0;
                    responseMessage = null;
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

    // Copy only completed, small, explicitly cacheable GETs. The cache's
    // eviction/expiry must never delete a file owned by a live connection.
    private static final class HttpCachedFile extends CachedFile {
        final int status;
        final String message;
        final List<String> keys, values;
        HttpCachedFile(String path, long expires, HttpURLConnection response) {
            super(path, expires);
            status = response.status;
            message = response.responseMessage;
            keys = new ArrayList<String>(response.headerKeys);
            values = new ArrayList<String>(response.headerValues);
        }
    }

    private static void deleteFile(String path) {
        if (path != null) {
            try { new File(path).delete(); } catch (Exception ignored) {}
        }
    }

    protected synchronized void releaseResponseFile() {
        String path = cacheFilePath;
        cacheFilePath = null;
        deleteFile(path);
    }

    @Override
    protected void finalize() throws Throwable {
        try { releaseResponseFile(); }
        finally { super.finalize(); }
    }

    private File copyFile(String path) throws IOException {
        File result = File.createTempFile(getCacheFileName(), ".tmp");
        boolean complete = false;
        try {
            InputStream in = new FileInputStream(path);
            try {
                OutputStream out = new FileOutputStream(result);
                try {
                    byte[] buf = new byte[1024];
                    int count;
                    while ((count = in.read(buf)) != -1) {
                        if (count == 0) {
                            int one = in.read();
                            if (one < 0) break;
                            out.write(one);
                        } else out.write(buf, 0, count);
                    }
                } finally { out.close(); }
            } finally { in.close(); }
            complete = true;
            return result;
        } finally {
            if (!complete) deleteFile(result.getAbsolutePath());
        }
    }

    private void addResponseHeader(String key, String value) {
        headerKeys.add(key);
        headerValues.add(value);
        if (key != null) {
            String lower = key.toLowerCase();
            List<String> values = rcvHeader.get(lower);
            if (values == null) {
                values = new ArrayList<String>();
                rcvHeader.put(lower, values);
            }
            values.add(value);
        }
    }

    private boolean restoreCachedResponse(String urlStr) {
        synchronized (caches) {
            CachedFile cached = caches.get(urlStr);
            if (cached == null) return false;
            if (cached.isExpired() || !(cached instanceof HttpCachedFile) ||
                    !(cached.resource instanceof String)) {
                if (cached.resource instanceof String) deleteFile((String) cached.resource);
                caches.remove(urlStr);
                return false;
            }
            HttpCachedFile entry = (HttpCachedFile) cached;
            try {
                File copy = copyFile((String) entry.resource);
                cacheFilePath = copy.getAbsolutePath();
                status = entry.status;
                responseMessage = entry.message;
                for (int i = 0; i < entry.keys.size(); i++)
                    addResponseHeader(entry.keys.get(i), entry.values.get(i));
                return true;
            } catch (IOException ignored) {
                deleteFile((String) entry.resource);
                caches.remove(urlStr);
                return false;
            }
        }
    }

    private void cacheCompletedResponse(String urlStr, long expires) {
        if (expires <= System.currentTimeMillis() || cacheFilePath == null ||
                new File(cacheFilePath).length() > MAX_REUSABLE_BODY) return;
        File copy = null;
        try {
            copy = copyFile(cacheFilePath);
            synchronized (caches) {
                cleanExpiredCaches();
                CachedFile previous = caches.put(urlStr,
                        new HttpCachedFile(copy.getAbsolutePath(), expires, this));
                if (previous != null && previous.resource instanceof String)
                    deleteFile((String) previous.resource);
                copy = null; // the cache now owns this file
            }
        } catch (IOException ignored) {
            // Caching is optional, not a failure of the completed request.
        } finally {
            if (copy != null) deleteFile(copy.getAbsolutePath());
        }
    }

    private void applyRequestHeaders() throws IOException {
        for (String key : outHeader.keySet()) {
            List<String> values = outHeader.get(key);
            if (values == null || values.isEmpty()) continue;
            StringBuilder joined = new StringBuilder();
            for (int i = 0; i < values.size(); i++) {
                if (i > 0) joined.append(',');
                joined.append(values.get(i));
            }
            connection.setRequestProperty(key, joined.toString());
        }
    }

    private void connectInternal() throws IOException {
        if (cacheFilePath != null) return;
        String urlStr = url.toString();
        boolean cacheable = useCaches && method.equals(HTTP_GET) && outHeader.isEmpty();
        if (cacheable && restoreCachedResponse(urlStr)) return;

        if (connection == null) {
            Connection con = Connector.open(urlStr);
            if (!(con instanceof HttpConnection)) {
                if (con != null) con.close();
                throw new IOException("not an HTTP connection");
            }
            connection = (HttpConnection) con;
        }
        if (method.equals(HTTP_POST)) {
            connection.setRequestMethod(HttpConnection.POST);
            applyRequestHeaders();
            byte[] data = outData == null ? new byte[0] : outData.toByteArray();
            connection.setRequestProperty("Content-Length", String.valueOf(data.length));
            DataOutputStream output = connection.openDataOutputStream();
            try { output.write(data); output.flush(); }
            finally { output.close(); }
        } else {
            connection.setRequestMethod(HttpConnection.GET);
            applyRequestHeaders();
        }
        status = connection.getResponseCode();
        responseMessage = connection.getResponseMessage();
        if (status != HttpConnection.HTTP_OK)
            throw new IOException("Http status: " + status);

        headerKeys.clear();
        headerValues.clear();
        rcvHeader.clear();
        for (int i = 0; ; i++) {
            String key = connection.getHeaderFieldKey(i);
            String value = connection.getHeaderField(i);
            if (key == null && value == null) break;
            addResponseHeader(key, value);
        }

        // Match the bundled 2025 MiniJVM's disk-backed response, not an
        // unbounded Java byte[] which multiplies memory across parked tabs.
        File tmp = File.createTempFile(getCacheFileName(), ".tmp");
        boolean complete = false;
        try {
            InputStream in = connection.openDataInputStream();
            try {
                OutputStream out = new FileOutputStream(tmp);
                try {
                    byte[] buf = new byte[1024];
                    for (;;) {
                        int len = in.read(buf);
                        if (jarboxHttpTimedOut() != 0)
                            throw new SocketTimeoutException("HTTP read timeout");
                        if (len < 0) break;
                        if (len == 0) {
                            int one = in.read();
                            if (jarboxHttpTimedOut() != 0)
                                throw new SocketTimeoutException("HTTP read timeout");
                            if (one < 0) break;
                            out.write(one);
                        } else out.write(buf, 0, len);
                    }
                } finally { out.close(); }
            } finally { in.close(); }
            if (jarboxHttpTimedOut() != 0)
                throw new SocketTimeoutException("HTTP read timeout");
            cacheFilePath = tmp.getAbsolutePath();
            complete = true;
        } finally {
            if (!complete) deleteFile(tmp.getAbsolutePath());
        }
        if (cacheable && jarboxHttpTimedOut() == 0)
            cacheCompletedResponse(urlStr, connection.getExpiration());
    }

    @Override
    public InputStream getInputStream() throws IOException {
        connect();
        return new FileInputStream(cacheFilePath);
    }

    public int getResponseCode() throws IOException {
        connect();
        return status;
    }

    public String getResponseMessage() throws IOException {
        connect();
        return responseMessage;
    }

    public String getHeaderField(int index) {
        try { connect(); } catch (IOException e) { return null; }
        return index >= 0 && index < headerValues.size() ? headerValues.get(index) : null;
    }

    public String getHeaderFieldKey(int index) {
        try { connect(); } catch (IOException e) { return null; }
        return index >= 0 && index < headerKeys.size() ? headerKeys.get(index) : null;
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
