/* SPDX-License-Identifier: MIT
 * Original: digitalgust/miniJVM, gust.
 * Null guard from upstream fef63db33f32dc27794fc50c54865e8d2244b895.
 * Compiled against the bundled miniJVM boot classes, not desktop java.net.
 */
package org.mini.urlhandler;

import java.io.IOException;
import java.net.HttpURLConnection;
import java.net.URL;
import java.net.URLConnection;
import java.net.URLStreamHandler;

public class HttpHandler extends URLStreamHandler {
    public URLConnection openConnection(URL url) throws IOException {
        return new HttpURLConnectionImpl(url);
    }

    static class HttpURLConnectionImpl extends HttpURLConnection {
        protected HttpURLConnectionImpl(URL url) {
            super(url);
        }

        @Override
        public synchronized void disconnect() {
            try {
                if (connection != null) {
                    connection.close();
                }
            } catch (IOException e) {
                throw new RuntimeException(e);
            } finally {
                connection = null;
                releaseResponseFile();
            }
        }
    }
}
