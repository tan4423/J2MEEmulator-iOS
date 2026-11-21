/* SPDX-License-Identifier: MIT */
package java.nio.charset;

/**
 * The Java 7+ UTF-8 constant required by PC-oriented J2ME mods.
 * The miniJVM Charset.forName implementation already supplies UTF-8.
 *
 * Only expose encodings supported by the bundled CLDC converters; do not
 * mislabel unsupported charsets as UTF-8.
 */
public final class StandardCharsets {
    private StandardCharsets() { }

    public static final Charset UTF_8 = Charset.forName("UTF-8");
}
