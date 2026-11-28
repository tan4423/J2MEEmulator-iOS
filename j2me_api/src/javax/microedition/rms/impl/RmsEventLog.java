package javax.microedition.rms.impl;

import java.io.File;
import java.io.FileOutputStream;
import java.io.IOException;

/**
 * Metadata-only audit for RMS/save settings. Each miniJVM has its own
 * java.lang.System properties and static class state; the save root is set
 * by the native session owner, never guessed from the MIDlet display title.
 *
 * This is intentionally NOT a replay/backup format. No record bytes, secrets,
 * usernames, store names, paths, IP addresses or game text are written.
 * A bounded number of I/O events are appended only when RMS is accessed;
 * there is no polling, timer or work during the Treo idle loop.
 */
public final class RmsEventLog {
    private static final int MAX_EVENTS_PER_JVM = 512;
    private static final long MAX_LOG_BYTES = 128L * 1024L;
    private static int count;

    private RmsEventLog() {}

    public static void note(String operation, String storeName,
                            int recordId, int bytes) {
        // OPEN is a hot-path diagnostic, not a persistence event. Writing a
        // file (or taking the logger lock) for every paint-time RMS open can
        // itself dominate the cost we are trying to measure.
        if ("OPEN".equals(operation) || "OPEN_CACHE".equals(operation)) return;
        synchronized (RmsEventLog.class) {
            if (count >= MAX_EVENTS_PER_JVM) return;
            String root = System.getProperty("app.save.root");
            if (root == null || root.length() == 0) return;
            if (!"CREATE".equals(operation) &&
                !"DELETE_STORE".equals(operation) &&
                !"SAVE".equals(operation) &&
                !"DELETE_RECORD".equals(operation) &&
                !"READ_ERROR".equals(operation) &&
                !"SAVE_ERROR".equals(operation) &&
                !"DELETE_ERROR".equals(operation)) return;
            File log = new File(root, "rms-events.log");
            if (log.exists() && log.length() >= MAX_LOG_BYTES) return;
            String id = storeName == null ? "0" : Integer.toHexString(storeName.hashCode());
            String row = System.currentTimeMillis() + "\tRMS_" + operation +
                         "\tstore#" + id + "\trecord=" + recordId +
                         "\tbytes=" + Math.max(-1, bytes) + "\n";
            FileOutputStream out = null;
            try {
                out = new FileOutputStream(log.getPath(), true);
                out.write(row.getBytes("UTF-8"));
                count++;
            } catch (IOException ignored) {
                // Logging must never turn a successful save into a failed save.
            } finally {
                if (out != null) {
                    try { out.close(); } catch (IOException ignored) {}
                }
            }
        }
    }}
