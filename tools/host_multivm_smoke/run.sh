#!/bin/bash
# Host multi-JVM smoke test. Usage: run.sh [asan|tsan|plain] [iterations]
set -euo pipefail
SAN=${1:-asan}; ITER=${2:-5}; SUITE=${3:-lifecycle}
OPT=-O1; LIMIT=120
case "$SUITE" in
  lifecycle) EXTRA=""; SCENARIOS="pair stop_a restart";;
  residual|residual_draw) EXTRA="-DJARBOX_HOST_RESIDUAL_TEST=1"; SCENARIOS="residual_diff residual_native_diff";;
  residual_resume) EXTRA="-DJARBOX_HOST_RESIDUAL_TEST=1"; SCENARIOS="residual_resume_diff";;
  intrinsics|benchmark)
    EXTRA="-DJARBOX_HOST_INTRINSIC_TEST=1 -DTREO_VM_CHAR_LEAF_EXPERIMENT=1 -DTREO_VM_ARRAY_LOOKUP_MODE1_EXPERIMENT=1"
    SCENARIOS=intrinsic_diff
    if [[ "$SUITE" == benchmark ]]; then
      [[ "$SAN" == plain ]] || { echo "Benchmark requires plain build" >&2; exit 2; }
      OPT=-O2; LIMIT=240; SCENARIOS=intrinsic_bench
    fi;;
  *) echo "Unknown suite: $SUITE" >&2; exit 2;;
esac
ROOT=$(cd "$(dirname "$0")/../.." && pwd); HERE=$ROOT/tools/host_multivm_smoke
CORE=$ROOT/J2MEEmulator/minijvm; BASE=${OUT:-/tmp/jbsmoke_build_$SAN}; mkdir -p "$BASE"
OUT=$(mktemp -d "$BASE/run.XXXXXX"); echo "Fresh build/log directory: $OUT"
# NOTE: alignment+shift-base UBSan checks are disabled: pre-existing benign interpreter idioms
# (unaligned u16 bytecode reads, shifts of negative bytes) that are unrelated to multi-JVM.
case $SAN in asan) SF="-fsanitize=address,undefined -fno-sanitize=alignment,shift-base -fno-omit-frame-pointer";; tsan) SF="-fsanitize=thread";; *) SF="";; esac
INC="-I$CORE/jvm -I$CORE/utils -I$CORE/utils/https -I$CORE/utils/https/mbedtls/include"
SRCS="$(ls $CORE/jvm/*.c | grep -v '/jit.c') $(ls $CORE/utils/*.c) $CORE/utils/https/mbedtls/library/net_sockets.c $CORE/utils/https/mbedtls/library/platform.c $HERE/stubs.c $HERE/smoke.c"
RT=$ROOT/J2MEEmulator/Resources/jars/minijvm_rt.jar; API=$ROOT/J2MEEmulator/Resources/jars/j2me_api.jar
APP="$OUT/app"
if [[ "$SUITE" == residual || "$SUITE" == residual_draw || "$SUITE" == residual_resume ]]; then
  ARGS=(); DRAW=()
  if [[ -n "${JARBOX_RESIDUAL_ARCHIVE:-}" ]]; then ARGS=(--archive "$JARBOX_RESIDUAL_ARCHIVE"); fi
  if [[ "$SUITE" == residual_draw ]]; then DRAW=(--draw-effects); fi
  if [[ "$SUITE" == residual_resume ]]; then DRAW=(--draw-effects --resume); fi
  python3 "$ROOT/tools/ninja_residual_fixture.py" "$OUT/fixtures" --bootclasspath "$RT" "${ARGS[@]}" "${DRAW[@]}"
  APP="$OUT/fixtures/original"
  python3 "$ROOT/tools/ninja_residual_native.py" "$APP" "$OUT/jarbox_host_residual_fixture.h" "${DRAW[@]}"
  INC="$INC -I$OUT"
  export UBSAN_OPTIONS=halt_on_error=1
  export ASAN_OPTIONS=halt_on_error=1
fi
gcc -g $OPT -rdynamic -fno-pie -no-pie -Dsignal=smoke_signal -w -std=gnu11 -pthread $SF $EXTRA $INC $SRCS -lm -o $OUT/smoke
mkdir -p $OUT/app
JAVAC="java -m jdk.compiler/com.sun.tools.javac.Main"
$JAVAC -nowarn -source 8 -target 8 -bootclasspath "$ROOT/J2MEEmulator/Resources/jars/minijvm_rt.jar" -d "$OUT/app" "$HERE/java/SmokeMain.java"
test -s "$OUT/app/SmokeMain.class"
if [[ "$SUITE" == intrinsics || "$SUITE" == benchmark ]]; then
  $JAVAC -nowarn -source 8 -target 8 -bootclasspath "$ROOT/J2MEEmulator/Resources/jars/minijvm_rt.jar" -d "$OUT/app" "$HERE/java/IntrinsicMain.java"
  test -s "$OUT/app/IntrinsicMain.class"
  export UBSAN_OPTIONS=halt_on_error=1
  export ASAN_OPTIONS=halt_on_error=1
fi
pass=0; fail=0
for sc in $SCENARIOS; do for i in $(seq 1 $ITER); do
  if timeout "$LIMIT" "$OUT/smoke" "$RT" "$API" "$APP" "$sc" >"$OUT/$sc.$i.log" 2>&1; then
    pass=$((pass+1))
    if [[ "$SUITE" == residual || "$SUITE" == residual_draw || "$SUITE" == residual_resume ]]; then
      grep -E "^residual_((native|resume)_)?diff: PASS|^residual native (calls|compiles|deopts):" "$OUT/$sc.$i.log"
    elif [[ "$SUITE" == intrinsics ]]; then
      grep -E '^intrinsics A:|^intrinsic_diff: PASS' "$OUT/$sc.$i.log"
    elif [[ "$SUITE" == benchmark ]]; then
      grep -E '^bench |^intrinsic_bench: PASS' "$OUT/$sc.$i.log"
      python3 "$HERE/benchmark_summary.py" "$OUT/$sc.$i.log"
    fi
  else
    fail=$((fail+1)); echo "FAIL $sc #$i (log: $OUT/$sc.$i.log)"
    if [[ "$SUITE" != lifecycle ]]; then tail -n 100 "$OUT/$sc.$i.log"; fi
  fi
done; done
echo "SUMMARY san=$SAN pass=$pass fail=$fail"; [ $fail -eq 0 ]
