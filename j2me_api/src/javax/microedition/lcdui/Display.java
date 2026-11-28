package javax.microedition.lcdui;

import javax.microedition.lcdui.event.EventQueue;
import javax.microedition.lcdui.event.Event;
import javax.microedition.lcdui.event.CanvasEvent;
import javax.microedition.lcdui.event.RunnableEvent;
import javax.microedition.midlet.MIDlet;

/**
 * J2ME Display — manages the current Displayable and render loop.
 * Analogous to J2ME-Loader's Display.
 */
public class Display {
    private static volatile Display instance;

    // Visibility query without creating a Display during startup or shutdown.
    static boolean isCurrentCanvas(Canvas canvas) {
        Display display = instance;
        return display != null && display.current == canvas;
    }
    private volatile Displayable current;
    private final Object screenChange = new Object();
    private volatile boolean running;
    private static final EventQueue eventQueue = new EventQueue();
    private MIDlet currentMIDlet;
    // Only Display's event loop owns these references. The regular MIDP screen
    // switch remains authoritative when a game opens another screen in sleep.
    private Canvas angelSleepOriginal;
    private Canvas angelSleepCanvas;

    private static final class SleepCanvas extends Canvas {
        SleepCanvas() { super(true); }
        protected void paint(Graphics g) {
            g.setColor(0);
            g.fillRect(0, 0, getWidth(), getHeight());
        }
    }

    private void applyAngelSleep(boolean enabled) {
        if (enabled) {
            if (angelSleepCanvas != null) return;
            Displayable original = current;
            if (!(original instanceof Canvas)) {
                System.out.println("[AngelSleep] no Canvas; compatible blackout only");
                return;
            }
            angelSleepOriginal = (Canvas) original;
            angelSleepCanvas = new SleepCanvas();
            if (!setCurrentIfExpected(angelSleepCanvas, original, true)) {
                angelSleepOriginal = null;
                angelSleepCanvas = null;
                System.out.println("[AngelSleep] screen changed; compatible blackout only");
            } else {
                System.out.println("[AngelSleep] entered");
            }
        } else {
            Canvas original = angelSleepOriginal;
            Canvas sleeper = angelSleepCanvas;
            angelSleepOriginal = null;
            angelSleepCanvas = null;
            if (sleeper == null || original == null) return;
            if (setCurrentIfExpected(original, sleeper, true)) {
                original.requestFullRepaint();
                System.out.println("[AngelSleep] restored");
            } else {
                // Never replace a newer screen with an obsolete pre-sleep Canvas.
                System.out.println("[AngelSleep] game changed screen; preserved new screen");
            }
        }
    }

    // Screen dimensions (configurable via system properties)
    private static int screenWidth = 240;
    private static int screenHeight = 320;

    static {
        String w = System.getProperty("j2me.screen.width");
        String h = System.getProperty("j2me.screen.height");
        if (w != null) try { screenWidth = Integer.parseInt(w); } catch (Exception e) {}
        if (h != null) try { screenHeight = Integer.parseInt(h); } catch (Exception e) {}
    }

    private Display() {
    }

    public static Display getDisplay(MIDlet midlet) {
        if (instance == null) {
            instance = new Display();
        }
        if (midlet != null) {
            instance.currentMIDlet = midlet;
        }
        return instance;
    }

    public void setCurrent(Displayable d) {
        setCurrentIfExpected(d, null, false);
    }

    private boolean setCurrentIfExpected(Displayable d, Displayable expected, boolean conditional) {
        if (d == null) return false;
        Displayable old;
        synchronized (screenChange) {
            if (conditional && current != expected) return false;
            NativeBridge.lockScreen();
            try {
                old = current;
                current = d;

                d.width = screenWidth;
                d.height = screenHeight;

                if (d instanceof Canvas) {
                    // Pass canvas commands to native (for soft-key display)
                    java.util.ArrayList<Command> cmds = d.getCommands();
                    NativeBridge.formBegin("", 0); // reset command buffer
                    for (int i = 0; i < cmds.size(); i++) {
                        Command c = cmds.get(i);
                        NativeBridge.formAddCommand(c.getLabel(), c.getCommandType(), c.getPriority(), i);
                    }
                    NativeBridge.showCanvas();
                } else if (d instanceof TextBox) {
                    ((TextBox) d).showNative();
                } else if (d instanceof Form) {
                    ((Form) d).showNative();
                } else if (d instanceof List) {
                    ((List) d).showNative();
                } else if (d instanceof Alert) {
                    ((Alert) d).showNative();
                }
            } finally {
                NativeBridge.unlockScreen();
            }
        }
        if (d instanceof Canvas && current == d) {
            Canvas canvas = (Canvas) d;
            canvas.initContext();
            canvas.repaintPending = true;
            canvas.showNotify();
        }

        if (old instanceof Canvas && old != d) {
            ((Canvas) old).hideNotify();
            ((Canvas) old).destroyContext();
        }
        NativeBridge.displayWake();
        return true;
    }

    public void setCurrent(Alert alert, Displayable nextDisplayable) {
        alert.nextDisplayable = nextDisplayable;
        setCurrent(alert);
    }

    public Displayable getCurrent() {
        return current;
    }

    public void callSerially(Runnable r) {
        if (r != null) {
            Display.eventQueue.postEvent(RunnableEvent.getInstance(r));
        }
    }

    /**
     * Post an event to the event queue (analogous to J2ME-Loader's Display.postEvent).
     */
    public static void postEvent(Event event) {
        Display.eventQueue.postEvent(event);
    }

    // --- Display capabilities (MIDP 2.0) ---

    public boolean isColor() { return true; }
    public int numColors() { return 16777216; } // 24-bit (2^24)
    public int numAlphaLevels() { return 256; } // 8-bit alpha
    public boolean flashBacklight(int duration) { return false; }
    public int getBestImageHeight(int imageType) { return 0; }
    public int getBestImageWidth(int imageType) { return 0; }
    public int getBorderStyle(boolean highlighted) {
        return highlighted ? Graphics.SOLID : Graphics.DOTTED;
    }
    public int getColor(int colorSpecifier) { return 0; }

    // --- Vibration ---

    public boolean vibrate(int duration) {
        if (duration < 0) throw new IllegalArgumentException();
        NativeBridge.vibrate(duration);
        return true;
    }

    // --- Screen size ---

    public static int getScreenWidth() { return screenWidth; }
    public static int getScreenHeight() { return screenHeight; }

    // --- Render loop ---

    /**
     * Run the render/event loop. Blocks until MIDlet calls notifyDestroyed().
     * Called by MIDletRunner after startApp().
     */
    public void runEventLoop() {
        running = true;
        eventQueue.startProcessing();
        System.out.println("[Display] Event loop started (" + screenWidth + "x" + screenHeight + ")");

        while (running && !MIDlet.isDestroyRequested()) {
            // Capture BEFORE checking input/repaint so events cannot be lost.
            final boolean eventWait = NativeBridge.displayWaitEnabled();
            final int wakeGeneration = eventWait ? NativeBridge.displayWaitVersion() : 0;
            // 0. Check if native side requested stop (e.g. user pressed Back)
            if (NativeBridge.isStopRequested()) {
                System.out.println("[Display] Native stop requested, exiting event loop");
                MIDlet.requestDestroy();
                break;
            }

            // 1. Poll native input events and post to EventQueue
            int[] nativeEvent;
            while ((nativeEvent = NativeBridge.pollInputEvent()) != null) {
                int type = nativeEvent[0];
                if (type == 90) { // internal native control, never a MIDlet key
                    try {
                        applyAngelSleep(nativeEvent[1] != 0);
                    } catch (RuntimeException failure) {
                        System.out.println("[AngelSleep] transition error: " + failure);
                    }
                    continue;
                }
                Displayable target;
                synchronized (screenChange) {
                    if (type >= 10 && nativeEvent[1] != NativeBridge.screenRevision()) continue;
                    target = current;
                }
                if (type <= 2 && target instanceof Canvas) {
                    // Pointer event → post CanvasEvent
                    Canvas c = (Canvas) target;
                    int ceType = type == 0 ? CanvasEvent.POINTER_PRESSED :
                                 type == 1 ? CanvasEvent.POINTER_DRAGGED : CanvasEvent.POINTER_RELEASED;
                    Display.eventQueue.postEvent(CanvasEvent.getInstance(c, ceType, 0, (float)nativeEvent[1], (float)nativeEvent[2]));
                } else if (type >= 3 && type <= 5 && target instanceof Canvas) {
                    // Key event → post CanvasEvent
                    Canvas c = (Canvas) target;
                    int ceType = type == 3 ? CanvasEvent.KEY_PRESSED :
                                 type == 4 ? CanvasEvent.KEY_RELEASED : CanvasEvent.KEY_REPEATED;
                    Display.eventQueue.postEvent(CanvasEvent.getInstance(c, ceType, nativeEvent[3]));
                } else if (type == 10) {
                    int cmdId = nativeEvent[2];
                    if (target instanceof TextBox) {
                        char[] text = NativeBridge.takeText(0, nativeEvent[1]);
                        if (text != null) ((TextBox) target).setString(new String(text));
                    } else if (target instanceof Form) {
                        Form form = (Form) target;
                        for (int i = 0; i < form.size(); i++) {
                            Item item = form.get(i);
                            if (item instanceof TextField) {
                                char[] text = NativeBridge.takeText(i, nativeEvent[1]);
                                if (text != null) ((TextField) item).setString(new String(text));
                            } else if (item instanceof ChoiceGroup) {
                                char[] value = NativeBridge.takeText(i, nativeEvent[1]);
                                if (value != null) {
                                    ChoiceGroup group = (ChoiceGroup) item;
                                    try {
                                        int selected = Integer.parseInt(new String(value));
                                        if (selected >= 0 && selected < group.size()) {
                                            group.setSelectedIndex(selected, true);
                                        }
                                    } catch (NumberFormatException ignored) {}
                                }
                            }
                        }
                    }
                    if (target != null) target.fireCommandAction(cmdId);
                } else if (type == 11 && target instanceof List) {
                    ((List) target).handleListSelect(nativeEvent[2]);
                } else if (type == 12 && target instanceof Alert) {
                    Alert alert = (Alert) target;
                    if (alert.nextDisplayable != null) setCurrent(alert.nextDisplayable);
                }
            }

            // 2. Handle resumeRequest — call startApp() again
            if (MIDlet.isResumeRequested() && currentMIDlet != null) {
                try {
                    currentMIDlet.callStartApp();
                } catch (Exception e) {
                    System.out.println("[Display] resumeRequest startApp error: " + e.getMessage());
                }
            }

            int refreshAfterAfk = NativeBridge.takeAfkRefresh();
            // 3. Repaint if needed (Canvas only)
            if (current instanceof Canvas) {
                Canvas canvas = (Canvas) current;
                if (refreshAfterAfk == 2) {
                    canvas.refreshAfterAfk(true);
                } else if (canvas.repaintPending) {
                    canvas.doPaint();
                } else if (refreshAfterAfk == 1) {
                    canvas.refreshAfterAfk(false);
                } else if (NativeBridge.jarSparsePaintDue()) {
                    // Diagnostic: invoke genuine Java paint() sparingly, even
                    // if the JAR's treo mode stopped requesting repaint().
                    // Does not alter repaintPending or the game tick loop.
                    // Canvas.doPaint() already serializes with paintLock.
                    canvas.doPaint();
                }
            }

            // Sleep in short intervals so we react quickly to destroyRequested
            try {
                if (eventWait && NativeBridge.displayWaitEnabled()
                        && refreshAfterAfk == 0
                        && !(current instanceof Canvas && ((Canvas) current).repaintPending)) {
                    // 250ms watchdog for lifecycle paths without a wake signal.
                    NativeBridge.displayWaitIfUnchanged(wakeGeneration, 250);
                } else if (NativeBridge.afkSuspended()) {
                    // Same nominal cadence, fewer loader thread wakeups.
                    if (!MIDlet.isDestroyRequested()) Thread.sleep(16);
                } else {
                    for (int i = 0; i < 4 && !MIDlet.isDestroyRequested(); i++) {
                        Thread.sleep(4);
                    }
                }
            } catch (InterruptedException e) {
                break;
            }
        }

        eventQueue.stopProcessing();

        // Destroy current Canvas context to release native CGBitmapContext memory
        if (current instanceof Canvas) {
            ((Canvas) current).hideNotify();
            ((Canvas) current).destroyContext();
        }
        current = null;
        angelSleepOriginal = null;
        angelSleepCanvas = null;
        currentMIDlet = null;
        instance = null; // Reset for next MIDlet launch
        System.out.println("[Display] Event loop stopped");
    }

    /**
     * Stop the event loop.
     */
    public void stopEventLoop() {
        running = false;
        NativeBridge.displayWake();
    }
}
