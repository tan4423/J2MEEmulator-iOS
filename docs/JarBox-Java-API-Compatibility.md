# JarBox Java API Compatibility Audit

This read-only analyzer identifies potential missing external Java class, method,
and field references by comparing a game JAR's bytecode with the *actual*
JarBox runtime JARs. It does not execute any game code and never edits JARs.

Use Java 17+ for the optional test fixtures, Python 3.9+ for the tool.

\`\`\`sh
python3 tools/jar_api_audit.py \
  --boot J2MEEmulator/Resources/jars/minijvm_rt.jar \
  --api J2MEEmulator/Resources/jars/j2me_api.jar \
  --output /tmp/jarbox-api-report.json \
  /path/to/game.jar

python3 -m unittest discover -s tools/tests -p test_jar_api_audit.py
\`\`\`

Run against the **post-patch JARs** to include compatibility classes inserted by
Codemagic, such as StandardCharsets and LocalTime. A report against bundled
pre-patch files will overestimate missing APIs. To generate a post-patch report
inside the existing workflow, optionally set \`JARBOX_COMPAT_AUDIT_JAR\` to
an existing **local file path** available to the build, not an external URL.
No user JAR is uploaded and the report is not a build gate.

The inventory reports referenced external classes, missing class definitions,
missing method descriptors and missing fields. Inherited methods/fields are
checked. It deliberately does not fail builds for unused code references,
reflection, dynamically loaded classes, native calls, incomplete ancestor
hierarchies or behavioral differences. The tool does not address arbitrary
bytecode rewrites or version-specific game checks.

Prioritize implementing missing APIs in a shared, tested boot/J2ME runtime layer,
not adding game-specific bytecode patches. Use the working TrungDucTV build
as the regression baseline. Never alter the original JAR, the main branch,
Deep Treo behavior or session-token lifecycle to satisfy an audit warning.
