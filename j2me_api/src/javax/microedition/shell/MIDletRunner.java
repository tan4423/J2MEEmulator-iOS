/*
 * MIDletRunner — Java-based MIDlet launcher for iOS/miniJVM.
 *
 * Replaces J2ME-Loader's MicroLoader + MidletThread + MicroActivity.
 * Reads the MIDlet JAR manifest, loads the MIDlet class via reflection,
 * and manages the MIDlet lifecycle (startApp/pauseApp/destroyApp).
 */
package javax.microedition.shell;

import javax.microedition.midlet.MIDlet;
import javax.microedition.midlet.MIDletStateChangeException;
import javax.microedition.lcdui.Canvas;
import javax.microedition.lcdui.Display;
import javax.microedition.lcdui.NativeBridge;
import java.io.BufferedReader;
import java.io.InputStream;
import java.io.InputStreamReader;
import java.util.HashMap;
import java.util.Map;
import java.util.zip.ZipEntry;
import java.util.zip.ZipFile;

public class MIDletRunner {

    /**
     * Entry point. Args:
     *   args[0] = path to MIDlet JAR file
     *   args[1] = (optional) MIDlet class name override
     */
    public static void main(String[] args) {
        if (args == null || args.length < 1) {
            System.out.println("[MIDletRunner] ERROR: Usage: MIDletRunner <midlet.jar> [ClassName]");
            return;
        }

        String jarPath = args[0];
        String classNameOverride = (args.length > 1) ? args[1] : null;

        System.out.println("[MIDletRunner] Loading MIDlet JAR: " + jarPath);
        // runLifecycle catches/reports the *original* throwable. Do not
        // overwrite that detail with the wrapper thrown to signal exit code 1.
        boolean enteredLifecycle = false;

        try {
            // 1. Read manifest
            long phaseStarted = System.nanoTime();
            Map<String, String> manifestAttrs = readManifest(jarPath);
            NativeBridge.startupPhase(1, System.nanoTime() - phaseStarted);

            String midletName = manifestAttrs.get("MIDlet-Name");
            String midletVersion = manifestAttrs.get("MIDlet-Version");
            System.out.println("[MIDletRunner] MIDlet-Name: " + midletName);
            System.out.println("[MIDletRunner] MIDlet-Version: " + midletVersion);

            // 2. Determine MIDlet class name
            String className;
            if (classNameOverride != null && !classNameOverride.isEmpty()) {
                className = classNameOverride;
            } else {
                className = parseMIDletClassName(manifestAttrs);
            }

            if (className == null || className.length() == 0) {
                throw new IllegalArgumentException("No MIDlet class found in JAR manifest");
            }
            System.out.println("[MIDletRunner] MIDlet class: " + className);

            // 3. Initialize properties (manifest attributes available to MIDlet)
            MIDlet.initProps(manifestAttrs);
            MIDlet.resetDestroyRequest();

            // Apply FPS limit from system property (set by iOS native side)
            String fpsStr = System.getProperty("j2me.fps.limit");
            if (fpsStr != null) {
                try {
                    Canvas.setLimitFps(Integer.parseInt(fpsStr));
                } catch (NumberFormatException ignored) {}
            }

            // 4. Load and instantiate MIDlet class
            System.out.println("[MIDletRunner] Loading class: " + className);
            phaseStarted = System.nanoTime();
            Class<?> clazz = Class.forName(className);
            NativeBridge.startupPhase(2, System.nanoTime() - phaseStarted);
            phaseStarted = System.nanoTime();
            MIDlet midlet = (MIDlet) clazz.newInstance();
            NativeBridge.startupPhase(3, System.nanoTime() - phaseStarted);

            // 5. Run lifecycle
            enteredLifecycle = true;
            runLifecycle(midlet);

        } catch (Throwable e) {
            // Never report a startup failure as an apparently normal app exit.
            // Propagate through call_main() so native runMIDlet returns a
            // nonzero status and iOS shows a launch-failure alert.
            System.out.println("[MIDletRunner] LAUNCH FAILURE: "
                + e.getClass().getName() + ": " + e.getMessage());
            e.printStackTrace();
            if (!enteredLifecycle) {
                NativeBridge.reportLaunchError(launcherDiagnostic("load/constructor", e));
            }
            throw new RuntimeException("MIDlet launch failed: " + e.toString());
        }
    }

    /**
     * Only invoked on a Java startup failure; no allocations on game ticks.
     * The miniJVM runtime may expose incomplete exception traces, so a trace
     * retrieval error is safely ignored and the original failure preserved.
     */
    private static String launcherDiagnostic(String stage, Throwable failure) {
        StringBuilder result = new StringBuilder(256);
        result.append("phase=").append(stage);
        result.append("; ").append(failure.getClass().getName());
        if (failure.getMessage() != null)
            result.append(": ").append(failure.getMessage());
        try {
            StackTraceElement[] stack = failure.getStackTrace();
            if (stack != null) {
                for (int i = 0; i < stack.length && i < 6; ++i) {
                    if (stack[i] != null)
                        result.append(" | ").append(stack[i].toString());
                }
            }
        } catch (Throwable ignored) {
            result.append(" | stack_unavailable");
        }
        return result.toString();
    }

    /**
     * Read all attributes from the JAR's META-INF/MANIFEST.MF using ZipFile.
     * Manual parsing since miniJVM's JarFile.getManifest().getMainAttributes()
     * is not fully implemented.
     */
    private static Map<String, String> readManifest(String jarPath) throws Exception {
        Map<String, String> result = new HashMap<String, String>();

        ZipFile zipFile = new ZipFile(jarPath);
        try {
            ZipEntry entry = zipFile.getEntry("META-INF/MANIFEST.MF");
            if (entry == null) {
                System.out.println("[MIDletRunner] WARNING: No MANIFEST.MF in JAR");
                return result;
            }

            InputStream is = zipFile.getInputStream(entry);
            BufferedReader reader = new BufferedReader(new InputStreamReader(is, "UTF-8"));

            String lastKey = null;
            String line;
            while ((line = reader.readLine()) != null) {
                if (line.isEmpty()) continue;

                // Continuation line (starts with space)
                if (line.charAt(0) == ' ' && lastKey != null) {
                    String prev = result.get(lastKey);
                    result.put(lastKey, prev + line.substring(1));
                    continue;
                }

                int colon = line.indexOf(':');
                if (colon > 0) {
                    String key = line.substring(0, colon).trim();
                    String value = line.substring(colon + 1).trim();
                    result.put(key, value);
                    lastKey = key;
                }
            }
            reader.close();
        } finally {
            zipFile.close();
        }

        return result;
    }

    /**
     * Parse the MIDlet class name from MIDlet-1 attribute.
     * Format: "Name, Icon, ClassName"
     */
    private static String parseMIDletClassName(Map<String, String> attrs) {
        // Try MIDlet-1 first
        String midlet1 = attrs.get("MIDlet-1");
        if (midlet1 == null) {
            // Try any MIDlet-N
            for (Map.Entry<String, String> entry : attrs.entrySet()) {
                String key = entry.getKey();
                if (key.startsWith("MIDlet-") && !key.equals("MIDlet-Name")
                        && !key.equals("MIDlet-Version")
                        && !key.equals("MIDlet-Vendor")) {
                    midlet1 = entry.getValue();
                    break;
                }
            }
        }

        if (midlet1 == null) return null;

        System.out.println("[MIDletRunner] MIDlet-1: " + midlet1);

        // Parse "Name, Icon, ClassName"
        String[] parts = midlet1.split(",");
        if (parts.length >= 3) {
            return parts[2].trim();
        } else if (parts.length == 1) {
            return parts[0].trim();
        }

        return null;
    }

    /**
     * Run the MIDlet lifecycle: startApp → (wait) → pauseApp → destroyApp
     */
    private static void runLifecycle(MIDlet midlet) {
        String stage = "startApp";
        try {
            // startApp
            System.out.println("[MIDletRunner] >>> Calling startApp()");
            long started = System.nanoTime();
            midlet.callStartApp();
            NativeBridge.startupPhase(4, System.nanoTime() - started);
            System.out.println("[MIDletRunner] <<< startApp() returned");

            // Run event/render loop — blocks until MIDlet calls notifyDestroyed().
            // Always run the loop — MIDlet may set Display.setCurrent()
            // asynchronously from its own thread (e.g. Gravity Defied).
            // If native stop was already requested (user pressed Back during init/startApp),
            // the loop will detect it on the first iteration and exit immediately.
            stage = "Display.runEventLoop";
            Display display = Display.getDisplay(midlet);
            display.runEventLoop();

            // pauseApp
            if (!MIDlet.isDestroyRequested()) {
                stage = "pauseApp";
                System.out.println("[MIDletRunner] >>> Calling pauseApp()");
                midlet.callPauseApp();
                System.out.println("[MIDletRunner] <<< pauseApp() returned");
            }

            // destroyApp
            stage = "destroyApp";
            System.out.println("[MIDletRunner] >>> Calling destroyApp(true)");
            midlet.callDestroyApp(true);
            System.out.println("[MIDletRunner] <<< destroyApp() returned");

            System.out.println("[MIDletRunner] MIDlet lifecycle complete");

        } catch (MIDletStateChangeException e) {
            System.out.println("[MIDletRunner] MIDletStateChangeException: " + e.getMessage());
            NativeBridge.reportLaunchError(launcherDiagnostic(stage, e));
            throw new RuntimeException("MIDlet lifecycle failed at " + stage + ": " + e.toString());
        } catch (Throwable e) {
            System.out.println("[MIDletRunner] ERROR in lifecycle: " + e.getClass().getName()
                    + ": " + e.getMessage());
            e.printStackTrace();
            NativeBridge.reportLaunchError(launcherDiagnostic(stage, e));
            throw new RuntimeException("MIDlet lifecycle failed at " + stage + ": " + e.toString());
        }
    }
}
