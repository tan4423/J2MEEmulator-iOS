#!/bin/bash
# Host multi-JVM smoke test. Usage: run.sh [asan|tsan|plain] [iterations]
set -e
SAN=${1:-asan}; ITER=${2:-5}
ROOT=$(cd "$(dirname "$0")/../.." && pwd); HERE=$ROOT/tools/host_multivm_smoke
CORE=$ROOT/J2MEEmulator/minijvm; OUT=${OUT:-/tmp/jbsmoke_build_$SAN}; mkdir -p $OUT
# NOTE: alignment+shift-base UBSan checks are disabled: pre-existing benign interpreter idioms
# (unaligned u16 bytecode reads, shifts of negative bytes) that are unrelated to multi-JVM.
case $SAN in asan) SF="-fsanitize=address,undefined -fno-sanitize=alignment,shift-base -fno-omit-frame-pointer";; tsan) SF="-fsanitize=thread";; *) SF="";; esac
INC="-I$CORE/jvm -I$CORE/utils -I$CORE/utils/https -I$CORE/utils/https/mbedtls/include"
SRCS="$(ls $CORE/jvm/*.c | grep -v '/jit.c') $(ls $CORE/utils/*.c) $CORE/utils/https/mbedtls/library/net_sockets.c $CORE/utils/https/mbedtls/library/platform.c $HERE/stubs.c $HERE/smoke.c"
gcc -g -O1 -rdynamic -fno-pie -no-pie -Dsignal=smoke_signal -w -std=gnu11 -pthread $SF $INC $SRCS -lm -o $OUT/smoke
mkdir -p $OUT/app
JAVAC="java -m jdk.compiler/com.sun.tools.javac.Main"
$JAVAC -nowarn -source 8 -target 8 -bootclasspath $ROOT/J2MEEmulator/Resources/jars/minijvm_rt.jar -d $OUT/app $HERE/java/SmokeMain.java 2>&1 | grep -v warning || true
RT=$ROOT/J2MEEmulator/Resources/jars/minijvm_rt.jar; API=$ROOT/J2MEEmulator/Resources/jars/j2me_api.jar
pass=0; fail=0
for sc in pair stop_a restart; do for i in $(seq 1 $ITER); do
  if timeout 120 $OUT/smoke $RT $API $OUT/app $sc >$OUT/$sc.$i.log 2>&1; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL $sc #$i (log: $OUT/$sc.$i.log)"; fi
done; done
echo "SUMMARY san=$SAN pass=$pass fail=$fail"; [ $fail -eq 0 ]
