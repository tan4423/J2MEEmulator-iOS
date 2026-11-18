package javax.microedition.lcdui;

/**
 * J2ME Canvas — the main class for custom rendering in MIDlets.
 * Uses offscreen CGBitmapContext via NativeBridge for double-buffered rendering.
 */
public abstract class Canvas extends Displayable {
    // Game action constants
    public static final int UP = 1;
    public static final int DOWN = 6;
    public static final int LEFT = 2;
    public static final int RIGHT = 5;
    public static final int FIRE = 8;
    public static final int GAME_A = 9;
    public static final int GAME_B = 10;
    public static final int GAME_C = 11;
    public static final int GAME_D = 12;

    // Key code constants (negative values for special keys, as per J2ME spec)
    public static final int KEY_UP = -1;
    public static final int KEY_DOWN = -2;
    public static final int KEY_LEFT = -3;
    public static final int KEY_RIGHT = -4;
    public static final int KEY_FIRE = -5;
    public static final int KEY_SOFT_LEFT = -6;
    public static final int KEY_SOFT_RIGHT = -7;
    public static final int KEY_CLEAR = -8;
    public static final int KEY_SEND = -10;
    public static final int KEY_END = -11;

    public static final int KEY_NUM0 = 48;
    public static final int KEY_NUM1 = 49;
    public static final int KEY_NUM2 = 50;
    public static final int KEY_NUM3 = 51;
    public static final int KEY_NUM4 = 52;
    public static final int KEY_NUM5 = 53;
    public static final int KEY_NUM6 = 54;
    public static final int KEY_NUM7 = 55;
    public static final int KEY_NUM8 = 56;
    public static final int KEY_NUM9 = 57;
    public static final int KEY_STAR = 42;
    public static final int KEY_POUND = 35;

    protected Canvas() { }
    protected Canvas(boolean fullScreen) { this.fullScreen = fullScreen; }

    private long nativeContext;
    private boolean treoSkippedCanvasPixels;
    private boolean treoUsesExplicitBuffer;
    private Graphics graphics;
    public volatile boolean repaintPending = true;
    private boolean fullScreen = false;
    // Dirty rect for partial repaint (J2ME clip region for paint())
    private int clipX, clipY, clipW, clipH;
    private boolean fullRepaint = true;
    // Lock to prevent concurrent doPaint from game thread + Display thread
    private final Object paintLock = new Object();

    // FPS limiting (matches J2ME-Loader's Canvas.limitFps)
    private static int fpsLimit;
    private long lastFrameTime = System.currentTimeMillis();

    public static void setLimitFps(int fps) {
        Canvas.fpsLimit = fps;
    }

    public static int getLimitFps() {
        return fpsLimit;
    }

    private void limitFps() {
        if (fpsLimit <= 0) return;
        try {
            long millis = (1000 / fpsLimit) - (System.currentTimeMillis() - lastFrameTime);
            if (millis > 0) Thread.sleep(millis);
        } catch (InterruptedException e) {
            e.printStackTrace();
        }
        lastFrameTime = System.currentTimeMillis();
    }

    /**
     * The abstract paint method — MIDlets override this.
     */
    protected abstract void paint(Graphics g);

    /**
     * Request a repaint of the entire canvas.
     */
    public void repaint() {
        repaint(0, 0, width, height);
    }

    public void repaint(int x, int y, int w, int h) {
        limitFps();
        if (!Display.isCurrentCanvas(this)) return;
        if (!repaintPending) {
            // First repaint request — set clip to this rect
            clipX = x;
            clipY = y;
            clipW = w;
            clipH = h;
            fullRepaint = (x == 0 && y == 0 && w >= width && h >= height);
        } else {
            // Accumulate: union of dirty rects
            int newRight = Math.max(clipX + clipW, x + w);
            int newBottom = Math.max(clipY + clipH, y + h);
            clipX = Math.min(clipX, x);
            clipY = Math.min(clipY, y);
            clipW = newRight - clipX;
            clipH = newBottom - clipY;
            if (clipX <= 0 && clipY <= 0 && clipW >= width && clipH >= height) {
                fullRepaint = true;
            }
        }
        repaintPending = true;
    }

    /**
     * Process all pending repaints synchronously.
     * Blocks until paint() completes, using EventQueue's callbackLock
     * to ensure serialized access (matching J2ME-Loader behavior).
     */
    public void serviceRepaints() {
        if (repaintPending && Display.isCurrentCanvas(this)) {
            doPaint();
        }
    }

    // TODO: Use EventQueue.serviceRepaints() for proper blocking when
    // called from a non-event thread. Current implementation is synchronous
    // which works for most J2ME games that call serviceRepaints() from
    // their game loop thread.

    public void setFullScreenMode(boolean mode) {
        this.fullScreen = mode;
    }

    // --- Internal rendering ---

    /**
     * Initialize the offscreen context. Called when canvas becomes current.
     */
    void initContext() {
        if (nativeContext == 0) {
            nativeContext = NativeBridge.createContext(width, height);
            graphics = new Graphics(nativeContext, width, height);
        }
    }

    // GameCanvas — copy offscreen buffer to Canvas context and flush to screen.
    // Synchronized on paintLock to prevent concurrent CGContext access.
    public void flushBuffer(Image image, int x, int y, int width, int height) {
        limitFps();
        if (width <= 0 || height <= 0 ||
                x + width < 0 || y + height < 0 ||
                x >= this.width || y >= this.height) {
            return;
        }
        synchronized (paintLock) {
            // Hidden Canvas instances must not run paint or present their buffer.
            if (!Display.isCurrentCanvas(this)) return;
            if (nativeContext == 0) initContext();
            treoUsesExplicitBuffer = true;
            graphics.reset(0, 0, this.width, this.height);
            graphics.drawImage(image, 0, 0, Graphics.LEFT | Graphics.TOP);
            if (Display.isCurrentCanvas(this)) NativeBridge.flushToScreen(nativeContext);
        }
    }

    // ExtendedImage (Siemens) — copy image to Canvas context at position and flush.
    public void flushBuffer(Image image, int x, int y) {
        limitFps();
        synchronized (paintLock) {
            // Hidden Canvas instances must not run paint or present their buffer.
            if (!Display.isCurrentCanvas(this)) return;
            if (nativeContext == 0) initContext();
            treoUsesExplicitBuffer = true;
            graphics.reset(0, 0, this.width, this.height);
            graphics.drawImage(image, x, y, Graphics.LEFT | Graphics.TOP);
            if (Display.isCurrentCanvas(this)) NativeBridge.flushToScreen(nativeContext);
        }
    }

    /**
     * Perform the paint cycle: clear → paint → flush.
     * Synchronized on paintLock to prevent concurrent CGContext access
     * from Display event loop thread and game thread.
     */
    public void doPaint() {
        synchronized (paintLock) {
            // Hidden Canvas instances must not run paint or present their buffer.
            if (!Display.isCurrentCanvas(this)) return;
            // Diagnostic only: consume the repaint without running game paint code.
            if (NativeBridge.afkBypassPaint()) {
                repaintPending = false;
                fullRepaint = true;
                clipX = 0; clipY = 0; clipW = width; clipH = height;
                return;
            }
            if (nativeContext == 0) initContext();
            repaintPending = false;
            // Use the same Graphics object, but switch its output for this paint only.
            final Graphics target = graphics;
            final int policy = NativeBridge.afkPaintPolicy();
            final boolean guarded = policy == 8;
            final boolean discard = guarded && !treoUsesExplicitBuffer && !target.treoPixelDependent &&
                    fullRepaint && !(this instanceof javax.microedition.lcdui.game.GameCanvas);
            final boolean headless = policy == 3 || policy == 4 || discard;
            final boolean rebuild = treoSkippedCanvasPixels && !headless;
            treoSkippedCanvasPixels = discard;
            final boolean previousHeadless = target.headless;
            final long previousAfkCanvas = NativeBridge.beginAfkPaint(nativeContext, headless);
            target.headless = headless;
            try {
                if (fullRepaint || rebuild) target.reset(0, 0, width, height);
                else target.reset(clipX, clipY, clipW, clipH);
                long profileStart = NativeBridge.profilePaintBegin();
                try {
                    paint(target);
                } finally {
                    if (profileStart != 0) NativeBridge.profilePaintEnd(profileStart);
                }
                if (Display.isCurrentCanvas(this)) NativeBridge.flushToScreen(nativeContext);
            } finally {
                target.headless = previousHeadless;
                NativeBridge.endAfkPaint(previousAfkCanvas);
                if (guarded) NativeBridge.afkCanvasResult(discard ? (target.treoPixelDependent ? 2 : 1) : 0);
            }
            // Reset for next frame
            fullRepaint = true;
            clipX = 0; clipY = 0; clipW = width; clipH = height;
        }
    }

    // Repaint after skipped raster; legacy blackout can publish the old buffer.
    void refreshAfterAfk(boolean redraw) {
        synchronized (paintLock) {
            if (nativeContext != 0 && Display.isCurrentCanvas(this)) {
                if (redraw) {
                    fullRepaint = true;
                    doPaint();
                } else {
                    NativeBridge.flushToScreen(nativeContext);
                }
            }
        }
    }

    void destroyContext() {
        synchronized (paintLock) {
            if (nativeContext != 0) {
                NativeBridge.destroyContext(nativeContext);
                nativeContext = 0;
                graphics = null;
            }
        }
    }

    // --- Capabilities ---

    public boolean hasPointerEvents() { return true; }
    public boolean hasPointerMotionEvents() { return true; }
    public boolean hasRepeatEvents() { return true; }
    public boolean isDoubleBuffered() { return true; }

    // --- Input ---

    protected void keyPressed(int keyCode) { }
    protected void keyReleased(int keyCode) { }
    protected void keyRepeated(int keyCode) { }
    protected void pointerPressed(int x, int y) { }
    protected void pointerReleased(int x, int y) { }
    protected void pointerDragged(int x, int y) { }
    protected void showNotify() { }
    protected void hideNotify() { }

    // Methods called by CanvasEvent.process() (matching J2ME-Loader's Canvas API)
    public void doKeyPressed(int keyCode) { postKeyPressed(keyCode); }
    public void doKeyReleased(int keyCode) { postKeyReleased(keyCode); }
    public void doKeyRepeated(int keyCode) { postKeyRepeated(keyCode); }

    // Overridden by GameCanvas for suppressCommands logic
    public void postKeyPressed(int keyCode) { keyPressed(keyCode); }
    public void postKeyReleased(int keyCode) { keyReleased(keyCode); }
    public void postKeyRepeated(int keyCode) { keyRepeated(keyCode); }
    public void pointerPressed(int pointer, float x, float y) { pointerPressed(Math.round(x), Math.round(y)); }
    public void pointerDragged(int pointer, float x, float y) { pointerDragged(Math.round(x), Math.round(y)); }
    public void pointerReleased(int pointer, float x, float y) { pointerReleased(Math.round(x), Math.round(y)); }
    public void doShowNotify() { showNotify(); }
    public void doHideNotify() { hideNotify(); }
    public void doSizeChanged(int w, int h) { sizeChanged(w, h); }

    // Public dispatch — called from Display event loop
    public void dispatchPointerEvent(int type, int x, int y) {
        switch (type) {
            case 0: pointerPressed(x, y); break;
            case 1: pointerDragged(x, y); break;
            case 2: pointerReleased(x, y); break;
        }
    }

    public void dispatchKeyEvent(int type, int keyCode) {
        switch (type) {
            case 3: keyPressed(keyCode); break;
            case 4: keyReleased(keyCode); break;
            case 5: keyRepeated(keyCode); break;
        }
    }

    public int getGameAction(int keyCode) {
        switch (keyCode) {
            case KEY_UP: case KEY_NUM2: return UP;
            case KEY_DOWN: case KEY_NUM8: return DOWN;
            case KEY_LEFT: case KEY_NUM4: return LEFT;
            case KEY_RIGHT: case KEY_NUM6: return RIGHT;
            case KEY_FIRE: case KEY_NUM5: return FIRE;
            case KEY_NUM7: return GAME_A;
            case KEY_NUM9: return GAME_B;
            case KEY_STAR: return GAME_C;
            case KEY_POUND: return GAME_D;
            default: return 0;
        }
    }

    public int getKeyCode(int gameAction) {
        switch (gameAction) {
            case UP: return KEY_NUM2;
            case DOWN: return KEY_NUM8;
            case LEFT: return KEY_NUM4;
            case RIGHT: return KEY_NUM6;
            case FIRE: return KEY_NUM5;
            default: return 0;
        }
    }

    public String getKeyName(int keyCode) {
        return "KEY_" + keyCode;
    }
}
