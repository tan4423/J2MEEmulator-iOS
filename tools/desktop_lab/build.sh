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
CORE="$ROOT/J2MEEmulator/minijvm"
# Same MiniJVM host build as host_multivm_smoke. TLS and JIT are deliberately
# unavailable in v0; never claim these stubs reproduce iOS transport.
# Desktop dependency include paths must not leak into core translation units.
COMMON=(-g -O2 -fno-pie -Dsignal=smoke_signal -DJARBOX_DESKTOP_LAB=1 -w -std=gnu11 -pthread
  -I"$CORE/jvm" -I"$CORE/utils" -I"$CORE/utils/https" -I"$CORE/utils/https/mbedtls/include")
gcc "${COMMON[@]}" $(pkg-config --cflags sdl2 cairo) -c tools/desktop_lab/lab.c -o "$RUNNER_TEMP/lab.o"
gcc "${COMMON[@]}" -rdynamic -no-pie \
  $(ls "$CORE"/jvm/*.c | grep -v '/jit.c') "$CORE"/utils/*.c \
  "$CORE/utils/https/mbedtls/library/net_sockets.c" "$CORE/utils/https/mbedtls/library/platform.c" \
  tools/host_multivm_smoke/stubs.c "$RUNNER_TEMP/lab.o" \
  $(pkg-config --libs sdl2 cairo) -lm -o "$OUT/jarbox-lab"
sha256sum "$OUT/jars/"*.jar "$OUT/jarbox-lab" > "$OUT/build-sha256.txt"
git rev-parse HEAD > "$OUT/source-commit.txt"
echo "Desktop lab build: $OUT"
