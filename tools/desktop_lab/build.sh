#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"
OUT=$(realpath -m "${1:-$ROOT/build/desktop-lab}")
mkdir -p "$OUT/jars"
cp J2MEEmulator/Resources/jars/{minijvm_rt,j2me_api}.jar "$OUT/jars/"
export RUNNER_TEMP=$(mktemp -d)
trap 'rm -rf "$RUNNER_TEMP"' EXIT
# Execute the exact shared Java patch block from the iOS build recipe on
# copies of the JARs. Refuse drift instead of silently running stale APIs.
python3 - "$OUT/jars" > "$RUNNER_TEMP/patch.sh" <<'PY'
import pathlib, shlex, sys
s=pathlib.Path("codemagic.yaml").read_text()
a='          jars="$PWD/J2MEEmulator/Resources/jars"\n'
b='          echo "[JarBoxNET][BUILD] socket=micro_compatible http/https=standard_dispatch"\n'
assert s.count(a)==1 and s.count(b)==1
body=s.split(a,1)[1].split(b,1)[0]+b
print("set -euo pipefail\njars="+shlex.quote(sys.argv[1]))
print("\n".join(line[10:] if line.startswith("          ") else line for line in body.splitlines()))
PY
bash "$RUNNER_TEMP/patch.sh"
python3 tools/generate_residual_build_identity.py "$OUT/jars" "$RUNNER_TEMP/jarbox_residual_build_identity.h"
CORE="$ROOT/J2MEEmulator/minijvm"
# Same MiniJVM host build, using the repository's real SSL transport.
# JIT remains disabled. Compile only the existing host JIT/crash shims.
# Desktop dependency include paths must not leak into core translation units.
COMMON=(-g -O2 -fno-pie -Dsignal=smoke_signal -DJARBOX_DESKTOP_LAB=1 -DJARBOX_BLOCK_IR_EXPERIMENT=1 -DJARBOX_DESKTOP_ARRAY_LOOKUP_TEST=1 -DTREO_VM_ARRAY_LOOKUP_MODE1_EXPERIMENT=1 -w -std=gnu11 -pthread
  -I"$CORE/jvm" -I"$CORE/utils" -I"$CORE/utils/https" -I"$CORE/utils/https/mbedtls/include")
case "${JARBOX_DESKTOP_GC_INDEX:-0}" in
  0) ;;
  1) COMMON+=(-DJARBOX_GC_DEFERRED_INDEX_EXPERIMENT=1) ;;
  *) echo "JARBOX_DESKTOP_GC_INDEX must be 0 or 1" >&2; exit 2 ;;
esac
printf 'gc_deferred_index=%s\n' "${JARBOX_DESKTOP_GC_INDEX:-0}" > "$OUT/build-profile.txt"
gcc "${COMMON[@]}" -I"$RUNNER_TEMP" $(pkg-config --cflags sdl2 cairo) -c tools/desktop_lab/lab.c -o "$RUNNER_TEMP/lab.o"
# Keep the identical tested JIT and signal shims, remove only the six TLS stubs.
sed '/^int sslc_/d' tools/host_multivm_smoke/stubs.c > "$RUNNER_TEMP/host-no-jit.c"
gcc "${COMMON[@]}" -rdynamic -no-pie \
  $(ls "$CORE"/jvm/*.c | grep -v '/jit.c') "$CORE"/utils/*.c \
  "$CORE/utils/https/ssl_client.c" "$CORE"/utils/https/mbedtls/library/*.c \
  "$RUNNER_TEMP/host-no-jit.c" "$RUNNER_TEMP/lab.o" \
  $(pkg-config --libs sdl2 cairo) -lm -o "$OUT/jarbox-lab"
(cd "$OUT"; sha256sum jars/*.jar jarbox-lab > build-sha256.txt)
cp tools/desktop_lab/{gui.py,labctl.py,Start-JarBox.cmd,start-wsl.sh,README.md} "$OUT/"
cp tools/desktop_lab/inspect.py "$OUT/lab_inspector.py"
chmod +x "$OUT/start-wsl.sh"
git rev-parse HEAD > "$OUT/source-commit.txt"
echo "Desktop lab build: $OUT"
