package javax.microedition.lcdui;

import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.IOException;
import java.io.InputStream;
import java.util.Enumeration;
import java.util.zip.ZipEntry;
import java.util.zip.ZipFile;

/**
 * J2ME Image — wraps a native CGImage/CGBitmapContext handle.
 * Analogous to J2ME-Loader's Image wrapping android.graphics.Bitmap.
 */
public class Image {
    public long nativeHandle; // RenderImage pointer
    private int width, height;
    private boolean mutable;

    private Graphics cachedGraphics;

    public Image(long nativeHandle, int width, int height, boolean mutable) {
        this.nativeHandle = nativeHandle;
        this.width = width;
        this.height = height;
        this.mutable = mutable;
    }

    public static Image createImage(int width, int height) {
        long handle = NativeBridge.createMutableImage(width, height);
        if (handle == 0) {
            System.out.println("[Image] ERROR: createMutableImage returned 0 for " + width + "x" + height);
        }
        return new Image(handle, width, height, true);
    }

    /**
     * Create a mutable image filled with the specified ARGB color.
     * When argb is 0, the image is fully transparent.
     */
    public static Image createImage(int width, int height, int argb) {
        Image img = createImage(width, height);
        if (argb != 0) {
            // Fill with the specified color
            int[] fill = new int[width * height];
            java.util.Arrays.fill(fill, argb);
            Graphics g = img.getGraphics();
            g.drawRGB(fill, 0, width, 0, 0, width, height, true);
        } else {
            // Clear to fully transparent by overwriting with transparent pixels
            int[] fill = new int[width * height];
            // fill is already all zeros (fully transparent)
            Graphics g = img.getGraphics();
            g.drawRGB(fill, 0, width, 0, 0, width, height, true);
        }
        return img;
    }

    public static Image createImage(String name) throws IOException {
        // The Java image and native handle are always owner-local. The
        // native decoder may reuse immutable pixel backing by exact bytes.
        final boolean useCache = name != null && NativeBridge.afkImageCacheEnabled();
        final ClassLoader loader = useCache ?
                Thread.currentThread().getContextClassLoader() : null;
        if (useCache) {
            byte[] cached = cachedResourceBytes(name, loader);
            if (cached != null) return createImage(cached, 0, cached.length);
        }
        InputStream is = findResource(name);
        if (is == null) {
            System.out.println("[Image] ERROR: resource not found: " + name);
            throw new IOException("Image resource not found: " + name);
        }
        if (!useCache) return createImage(is);
        byte[] data = readAllBytes(is);
        Image result = createImage(data, 0, data.length);
        // Do not cache absent or invalid images: decode must succeed first.
        cacheResourceBytes(name, loader, data);
        return result;
    }

    // Experimental, bounded compression-data cache for static JAR resources.
    // 128 direct-mapped entries, <=256 KiB each, <=2 MiB retained total.
    // Key includes the context classloader, not only the resource path.
    private static final int RESOURCE_SLOTS = 128;
    private static final int RESOURCE_MAX_ITEM = 256 * 1024;
    private static final int RESOURCE_MAX_BYTES = 2 * 1024 * 1024;

    private static final class ResourceEntry {
        final String name;
        final ClassLoader loader;
        final byte[] source;
        ResourceEntry(String name, ClassLoader loader, byte[] source) {
            this.name = name;
            this.loader = loader;
            this.source = source;
        }
    }
    private static final ResourceEntry[] resourceCache = new ResourceEntry[RESOURCE_SLOTS];
    private static int cachedByteCount;
    private static int evictionCursor;
    private static int hitBatch;

    private static int cacheSlot(String name) {
        return (name.hashCode() & 0x7fffffff) & (RESOURCE_SLOTS - 1);
    }
    private static synchronized byte[] cachedResourceBytes(String name, ClassLoader loader) {
        ResourceEntry entry = resourceCache[cacheSlot(name)];
        if (entry == null || entry.loader != loader || !entry.name.equals(name)) return null;
        if (++hitBatch == 64) {
            NativeBridge.imageCacheNote(64, 0);
            hitBatch = 0;
        }
        return entry.source;
    }
    private static synchronized void cacheResourceBytes(String name, ClassLoader loader,
                                                         byte[] source) {
        if (source == null || source.length == 0 || source.length > RESOURCE_MAX_ITEM) return;
        int slot = cacheSlot(name);
        ResourceEntry old = resourceCache[slot];
        if (old != null) cachedByteCount -= old.source.length;
        resourceCache[slot] = null;
        while (cachedByteCount + source.length > RESOURCE_MAX_BYTES) {
            ResourceEntry victim = resourceCache[evictionCursor];
            if (victim != null) {
                cachedByteCount -= victim.source.length;
                resourceCache[evictionCursor] = null;
            }
            evictionCursor = (evictionCursor + 1) & (RESOURCE_SLOTS - 1);
        }
        resourceCache[slot] = new ResourceEntry(name, loader, source);
        cachedByteCount += source.length;
        NativeBridge.imageCacheNote(0, source.length);
    }

    private static InputStream findResource(String name) {
        // Try exact name first via classloader
        InputStream is = tryLoadResource(name);
        if (is != null) return is;

        // If resource has no extension, search JARs on the classpath
        // for an entry whose name before the extension matches
        if (name.lastIndexOf('.') <= name.lastIndexOf('/')) {
            String searchName = name.startsWith("/") ? name.substring(1) : name;
            String match = findEntryByPrefix(searchName);
            if (match != null) {
                is = tryLoadResource("/" + match);
                if (is != null) return is;
            }
        }
        return null;
    }

    /**
     * Scan classpath JARs for an entry whose basename (without extension)
     * matches the given name. For example, searching for "bg1" will match "bg1.png".
     */
    private static String findEntryByPrefix(String name) {
        String cp = System.getProperty("java.class.path");
        if (cp == null) return null;
        String[] paths = cp.split(File.pathSeparator);
        for (String path : paths) {
            if (path == null || path.length() == 0) continue;
            File f = new File(path);
            if (!f.isFile()) continue;
            try {
                ZipFile zf = new ZipFile(f);
                Enumeration entries = zf.entries();
                while (entries.hasMoreElements()) {
                    ZipEntry entry = (ZipEntry) entries.nextElement();
                    String entryName = entry.getName();
                    int dotIdx = entryName.lastIndexOf('.');
                    if (dotIdx > 0) {
                        String baseName = entryName.substring(0, dotIdx);
                        if (baseName.equals(name)) {
                            zf.close();
                            return entryName;
                        }
                    }
                }
                zf.close();
            } catch (IOException e) {
                // skip this jar
            }
        }
        return null;
    }

    private static InputStream tryLoadResource(String name) {
        InputStream is = Image.class.getResourceAsStream(name);
        if (is == null && !name.startsWith("/")) {
            is = Image.class.getResourceAsStream("/" + name);
        }
        if (is == null) {
            ClassLoader cl = Thread.currentThread().getContextClassLoader();
            if (cl != null) {
                is = cl.getResourceAsStream(name);
                if (is == null && name.startsWith("/")) {
                    is = cl.getResourceAsStream(name.substring(1));
                }
            }
        }
        return is;
    }

    public static Image createImage(InputStream stream) throws IOException {
        byte[] data = readAllBytes(stream);
        return createImage(data, 0, data.length);
    }

    public static Image createImage(byte[] imageData, int imageOffset, int imageLength) {
        if (imageData == null) throw new NullPointerException();
        if (imageOffset < 0 || imageLength < 0 || imageOffset > imageData.length ||
                imageLength > imageData.length - imageOffset)
            throw new ArrayIndexOutOfBoundsException();
        long handle = NativeBridge.createImageFromData(imageData, imageOffset, imageLength);
        if (handle == 0) {
            throw new IllegalArgumentException("Failed to decode image data");
        }
        int w = NativeBridge.getImageWidth(handle);
        int h = NativeBridge.getImageHeight(handle);
        return new Image(handle, w, h, false);
    }

    public static Image createImage(Image source, int x, int y, int width, int height, int transform) {
        // Determine output size based on transform
        int outW = width, outH = height;
        if (transform == 5 || transform == 6 || transform == 7 || transform == 4) {
            // ROT90, ROT270, MIRROR_ROT90, MIRROR_ROT270 swap axes
            outW = height; outH = width;
        }
        Image result = createImage(outW, outH);
        Graphics g = result.getGraphics();
        g.drawRegion(source, x, y, width, height, transform, 0, 0, Graphics.LEFT | Graphics.TOP);
        // Mark as immutable but keep same object to avoid double-free
        result.mutable = false;
        return result;
    }

    public static Image createImage(Image source) {
        // Create mutable copy
        Image copy = createImage(source.width, source.height);
        Graphics g = copy.getGraphics();
        g.drawImage(source, 0, 0, Graphics.LEFT | Graphics.TOP);
        return copy;
    }

    public static Image createRGBImage(int[] rgb, int width, int height, boolean processAlpha) {
        Image img = createImage(width, height);
        Graphics g = img.getGraphics();
        g.drawRGB(rgb, 0, width, 0, 0, width, height, processAlpha);
        return img;
    }

    public Graphics getGraphics() {
        if (!mutable) {
            throw new IllegalStateException("Image is not mutable");
        }
        if (cachedGraphics == null) {
            long ctx = NativeBridge.getImageContext(nativeHandle);
            cachedGraphics = new Graphics(ctx, width, height);
            cachedGraphics.ownsContext = true;
        }
        return cachedGraphics;
    }

    public int getWidth() { return width; }
    public int getHeight() { return height; }
    public boolean isMutable() { return mutable; }

    public void getRGB(int[] rgbData, int offset, int scanlength,
                       int x, int y, int w, int h) {
        if (rgbData == null) throw new NullPointerException();
        if (x < 0 || y < 0 || w < 0 || h < 0 || x > width || y > height ||
                w > width - x || h > height - y) throw new IllegalArgumentException("image region");
        if (w == 0 || h == 0) return;
        if ((long)scanlength < w && -(long)scanlength < w)
            throw new IllegalArgumentException("scanlength");
        long last = (long)offset + (long)(h - 1) * scanlength;
        long low = last < offset ? last : offset;
        long high = last > offset ? last : offset;
        if (low < 0 || high + w > rgbData.length) throw new ArrayIndexOutOfBoundsException();
        NativeBridge.getImageRGB(nativeHandle, rgbData, offset, scanlength, x, y, w, h);
    }

    private static byte[] readAllBytes(InputStream is) throws IOException {
        ByteArrayOutputStream bos = new ByteArrayOutputStream(4096);
        byte[] buf = new byte[4096];
        int n;
        while ((n = is.read(buf)) > 0) {
            bos.write(buf, 0, n);
        }
        is.close();
        return bos.toByteArray();
    }

    protected void finalize() throws Throwable {
        // Don't destroy cachedGraphics.nativeContext here — the Graphics
        // object may still be in use on another thread's stack.
        // Graphics.finalize() will release its own RenderContext (ownsContext=true).
        cachedGraphics = null;
        if (nativeHandle != 0) {
            NativeBridge.destroyImage(nativeHandle);
            nativeHandle = 0;
        }
        super.finalize();
    }
}
