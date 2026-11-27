#!/bin/bash
# Host multi-JVM smoke test. Usage: run.sh [asan|tsan|plain] [iterations]
set -euo pipefail
SAN=${1:-asan}; ITER=${2:-5}; SUITE=${3:-lifecycle}
OPT=-O1; LIMIT=120
case "$SUITE" in
  lifecycle) EXTRA=""; SCENARIOS="pair stop_a restart";;
  residual|residual_draw) EXTRA="-DJARBOX_HOST_RESIDUAL_TEST=1"; SCENARIOS="residual_diff residual_native_diff";;
  residual_resume) EXTRA="-DJARBOX_HOST_RESIDUAL_TEST=1"; SCENARIOS="residual_resume_diff";;
  residual_read) EXTRA="-DJARBOX_HOST_RESIDUAL_TEST=1"; SCENARIOS="residual_native_diff";;
  residual_closed) EXTRA="-DJARBOX_HOST_RESIDUAL_TEST=1"; SCENARIOS="residual_closed_diff";;
  residual_extended) EXTRA="-DJARBOX_HOST_RESIDUAL_TEST=1 -DJARBOX_HOST_RESIDUAL_EXTENDED_TEST=1"; SCENARIOS="residual_extended_diff";;
  residual_wide) EXTRA="-DJARBOX_HOST_RESIDUAL_TEST=1 -DJARBOX_HOST_RESIDUAL_EXTENDED_TEST=1 -DJARBOX_HOST_RESIDUAL_WIDE_TEST=1"; SCENARIOS="residual_wide_diff";;
  residual_background) EXTRA="-DJARBOX_HOST_RESIDUAL_TEST=1 -DJARBOX_HOST_RESIDUAL_EXTENDED_TEST=1 -DJARBOX_HOST_RESIDUAL_WIDE_TEST=1 -DJARBOX_HOST_RESIDUAL_BACKGROUND_TEST=1"; SCENARIOS="residual_background_diff";;
  binding) EXTRA="-DJARBOX_HOST_BINDING_TEST=1"; SCENARIOS="binding_diff";;
  gc_index|gc_callbacks) EXTRA="-DJARBOX_HOST_INTRINSIC_TEST=1 -DJARBOX_GC_DEFERRED_INDEX_EXPERIMENT=1 -DJARBOX_HOST_GC_INDEX_TEST=1"; SCENARIOS="gc_index_diff";
    if [[ "$SUITE" == gc_callbacks ]]; then SCENARIOS="gc_index_callbacks"; fi;;
  render_island) EXTRA="-DJARBOX_HOST_INTRINSIC_TEST=1 -DJARBOX_HOST_RENDER_ISLAND_TEST=1"; SCENARIOS="render_island_diff";;
  block_ir) EXTRA="-DJARBOX_HOST_INTRINSIC_TEST=1 -DJARBOX_BLOCK_IR_EXPERIMENT=1 -DJARBOX_HOST_BLOCK_IR_TEST=1"; SCENARIOS="block_ir_diff block_ir_share";;
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
if [[ "$SUITE" == residual || "$SUITE" == residual_draw || "$SUITE" == residual_resume || "$SUITE" == residual_read || "$SUITE" == residual_closed ]]; then
  ARGS=(); DRAW=()
  if [[ -n "${JARBOX_RESIDUAL_ARCHIVE:-}" ]]; then ARGS=(--archive "$JARBOX_RESIDUAL_ARCHIVE"); fi
  if [[ "$SUITE" == residual_draw ]]; then DRAW=(--draw-effects); fi
  if [[ "$SUITE" == residual_resume ]]; then DRAW=(--draw-effects --resume); fi
  if [[ "$SUITE" == residual_read ]]; then DRAW=(--draw-effects --resolved-reads); fi
  if [[ "$SUITE" == residual_closed ]]; then DRAW=(--draw-effects --resume --skip-draws); fi
  python3 "$ROOT/tools/ninja_residual_fixture.py" "$OUT/fixtures" --bootclasspath "$RT" "${ARGS[@]}" "${DRAW[@]}"
  APP="$OUT/fixtures/original"
  python3 "$ROOT/tools/ninja_residual_native.py" "$APP" "$OUT/jarbox_host_residual_fixture.h" "${DRAW[@]}"
  INC="$INC -I$OUT"
  export UBSAN_OPTIONS=halt_on_error=1
  export ASAN_OPTIONS=halt_on_error=1
fi
if [[ "$SUITE" == residual_extended || "$SUITE" == residual_wide || "$SUITE" == residual_background ]]; then
  fixture=ninja_residual_extended_fixture.py
  opts=()
  if [[ "$SUITE" != residual_extended ]]; then fixture=ninja_residual_wide_fixture.py; fi
  if [[ "$SUITE" == residual_background ]]; then opts=(--background); fi
  python3 "$ROOT/tools/$fixture" "$OUT/extended" "$OUT/jarbox_host_residual_fixture.h" "$RT" "${opts[@]}"
  APP="$OUT/extended/classes"
  INC="$INC -I$OUT"
  export UBSAN_OPTIONS=halt_on_error=1
  export ASAN_OPTIONS=halt_on_error=1
fi
if [[ "$SUITE" == binding ]]; then
  python3 "$ROOT/tools/ninja_residual_binding_fixture.py" "$OUT/binding" "$OUT/jarbox_host_binding_fixture.h"
  APP="$OUT/binding/classes"
  INC="$INC -I$OUT"
  export UBSAN_OPTIONS=halt_on_error=1
  export ASAN_OPTIONS=halt_on_error=1
fi
gcc -g $OPT -rdynamic -fno-pie -no-pie -Dsignal=smoke_signal -w -std=gnu11 -pthread $SF $EXTRA $INC $SRCS -lm -o $OUT/smoke
mkdir -p $OUT/app
JAVAC="java -m jdk.compiler/com.sun.tools.javac.Main"
$JAVAC -nowarn -source 8 -target 8 -bootclasspath "$ROOT/J2MEEmulator/Resources/jars/minijvm_rt.jar" -d "$OUT/app" "$HERE/java/SmokeMain.java"
test -s "$OUT/app/SmokeMain.class"
if [[ "$SUITE" == intrinsics || "$SUITE" == benchmark || "$SUITE" == gc_index || "$SUITE" == gc_callbacks || "$SUITE" == block_ir || "$SUITE" == render_island ]]; then
  $JAVAC -nowarn -source 8 -target 8 -bootclasspath "$ROOT/J2MEEmulator/Resources/jars/minijvm_rt.jar" -d "$OUT/app" "$HERE/java/IntrinsicMain.java"
  test -s "$OUT/app/IntrinsicMain.class"
  if [[ "$SUITE" == gc_callbacks ]]; then
    $JAVAC -nowarn -source 8 -target 8 -bootclasspath "$RT" -d "$OUT/app" "$HERE/java/GcIndexMain.java"
    test -s "$OUT/app/GcIndexMain.class"
  fi
  if [[ "$SUITE" == block_ir ]]; then
    $JAVAC -nowarn -source 8 -target 8 -bootclasspath "$RT" -d "$OUT/app" "$HERE/java/BlockMain.java"
    test -s "$OUT/app/BlockMain.class"
  fi
  if [[ "$SUITE" == render_island ]]; then
    $JAVAC -nowarn -source 8 -target 8 -bootclasspath "$RT" -d "$OUT/app" "$HERE/java/RenderIslandMain.java"
    test -s "$OUT/app/RenderIslandMain.class"
  fi
  export UBSAN_OPTIONS=halt_on_error=1
  export ASAN_OPTIONS=halt_on_error=1
fi
pass=0; fail=0
for sc in $SCENARIOS; do for i in $(seq 1 $ITER); do
  if timeout "$LIMIT" "$OUT/smoke" "$RT" "$API" "$APP" "$sc" >"$OUT/$sc.$i.log" 2>&1; then
    pass=$((pass+1))
    if [[ "$SUITE" == residual || "$SUITE" == residual_draw || "$SUITE" == residual_resume || "$SUITE" == residual_read || "$SUITE" == residual_closed ]]; then
      grep -E "^residual_((native|resume|closed)_)?diff: PASS|^residual native (calls|compiles|deopts|skipped|suspended):" "$OUT/$sc.$i.log"
    elif [[ "$SUITE" == residual_extended || "$SUITE" == residual_wide || "$SUITE" == residual_background ]]; then
      grep -E "^residual_(extended|wide|background)_diff: PASS|^residual native (calls|compiles|deopts|skipped|suspended):|^residual cold deopts:" "$OUT/$sc.$i.log"
    elif [[ "$SUITE" == binding ]]; then
      grep -E "^binding (A|B):|^binding_diff: PASS" "$OUT/$sc.$i.log"
    elif [[ "$SUITE" == intrinsics ]]; then
      grep -E '^intrinsics A:|^intrinsic_diff: PASS' "$OUT/$sc.$i.log"
    elif [[ "$SUITE" == render_island ]]; then
      grep -E '^render islands B=|^render_island_diff: PASS' "$OUT/$sc.$i.log"
    elif [[ "$SUITE" == block_ir ]]; then
      grep -E '^block IR A=|^block shared A=|^block_ir_(diff|share): PASS' "$OUT/$sc.$i.log"
    elif [[ "$SUITE" == gc_index || "$SUITE" == gc_callbacks ]]; then
      grep -E '^gc index A=|^gc callbacks [AB] |^gc_index_(diff|callbacks): PASS' "$OUT/$sc.$i.log"
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
