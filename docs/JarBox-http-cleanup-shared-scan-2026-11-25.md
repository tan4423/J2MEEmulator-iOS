# NST HTTP cleanup and shared archive classification

Device 42665db: NST request_to_surface 808.4 ms, constructor 667.2 ms; TrungDucTV 885.6 ms, constructor 650.7 ms. Both faster in the supplied samples than 27522a4; not a controlled benchmark. Constructor is now the largest measured stage.

NST failure: original game bu.e PC17..105 catches Exception; PC143 invokes HttpURLConnection.disconnect. The recorded deepest NPE is HttpHandler$HttpURLConnectionImpl.disconnect PC4. Upstream miniJVM 231cf8e10557f5a088ad6132db52bfb38108d35a has unconditional connection.close(); upstream fef63db33f32dc27794fc50c54865e8d2244b895 adds the null guard. Apply that fix to the boot JAR only, preserving IOException behavior. CI compiles against bundled boot classes, checks nested binary API and packaged bytes. Add bounded nst_http_original trace before game cleanup. The original HTTP failure remains unknown, and login completion requires device confirmation.

Shared-game optimization: library preflight and native admission both scan all class bytes for 2D/3D safety. Cache only successful 2D results, keyed by exact path and file identity (device/inode/size/mtime/ctime including nanoseconds). 16 fixed-size records, no shared JVM state, no lock over archive scanning, invalidate on replacement. Unknown/exclusive scans remain fail-closed. Do not skip per-session admission or memory checks.

No change to game JAR, game version, RMS, tab limits, network protocol or JIT. TrungDucTV still shows the warning and the supplied trace lacks a version-status branch. Do not hide it. Further constructor optimization needs measured resource/decode/class-init costs.
