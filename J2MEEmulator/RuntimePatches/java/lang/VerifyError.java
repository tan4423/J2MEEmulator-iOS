/*
 * Minimal Java-8 compatible VerifyError for miniJVM's safe opcode fallback.
 * Do not substitute a successful result for unsupported bytecode.
 */
package java.lang;
public class VerifyError extends LinkageError {
    public VerifyError() { super(); }
    public VerifyError(String message) { super(message); }
}
