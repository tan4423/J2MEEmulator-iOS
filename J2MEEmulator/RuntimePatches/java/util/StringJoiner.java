/* SPDX-License-Identifier: MIT */
package java.util;

/**
 * Java 8 StringJoiner compatibility for JarBox's CLDC boot runtime.
 * No global state, network hooks, reflection or background work.
 */
public final class StringJoiner {
    private final String delimiter;
    private final String prefix;
    private final String suffix;
    private String emptyValue;
    private StringBuilder body;
    private boolean hasElements;

    public StringJoiner(CharSequence delimiter) {
        this(delimiter, "", "");
    }

    public StringJoiner(CharSequence delimiter, CharSequence prefix, CharSequence suffix) {
        if (delimiter == null) throw new NullPointerException("delimiter");
        if (prefix == null) throw new NullPointerException("prefix");
        if (suffix == null) throw new NullPointerException("suffix");
        this.delimiter = delimiter.toString();
        this.prefix = prefix.toString();
        this.suffix = suffix.toString();
        this.emptyValue = this.prefix + this.suffix;
    }

    public StringJoiner setEmptyValue(CharSequence emptyValue) {
        if (emptyValue == null) throw new NullPointerException("emptyValue");
        this.emptyValue = emptyValue.toString();
        return this;
    }

    public StringJoiner add(CharSequence newElement) {
        if (body == null) body = new StringBuilder();
        if (hasElements) body.append(delimiter);
        body.append(newElement == null ? "null" : newElement.toString());
        hasElements = true;
        return this;
    }

    public StringJoiner merge(StringJoiner other) {
        if (other == null) throw new NullPointerException("other");
        // The other joiner's separators belong inside this one element.
        // Copy first so merge(self) never aliases a mutating StringBuilder.
        if (other.hasElements) add(other.body.toString());
        return this;
    }

    public int length() {
        return hasElements ? prefix.length() + body.length() + suffix.length()
                           : emptyValue.length();
    }

    @Override
    public String toString() {
        return hasElements ? prefix + body.toString() + suffix : emptyValue;
    }
}
