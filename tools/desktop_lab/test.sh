#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
OUT=$(realpath "$1")
mkdir -p "$OUT/fixture/classes" "$OUT/fixture/save"
javac --release 8 -cp "$OUT/jars/j2me_api.jar" -d "$OUT/fixture/classes" "$ROOT/tools/desktop_lab/LabFixture.java"
printf 'Manifest-Version: 1.0\nMIDlet-Name: LabFixture\nMIDlet-Version: 1.0\nMIDlet-Vendor: JarBox\nMIDlet-1: LabFixture,,LabFixture\n\n' > "$OUT/fixture/manifest"
# Synthetic sprite atlas at the maximum actual Nick t5 PNG height.
python3 - "$OUT/fixture/classes/lab-tall.png" <<'PY'
import struct,zlib,pathlib,sys
w,h=24,3432
def chunk(t,d):
    return struct.pack(">I",len(d))+t+d+struct.pack(">I",zlib.crc32(t+d)&0xffffffff)
raw=(b'\x00'+b'\x33\x66\x99\xff'*w)*h
pathlib.Path(sys.argv[1]).write_bytes(b'\x89PNG\r\n\x1a\n'+chunk(b'IHDR',struct.pack(">IIBBBBB",w,h,8,6,0,0,0))+chunk(b'IDAT',zlib.compress(raw))+chunk(b'IEND',b''))
PY
jar cfm "$OUT/fixture/fixture.jar" "$OUT/fixture/manifest" -C "$OUT/fixture/classes" .
python3 "$ROOT/tools/desktop_lab/test_transport.py" "$OUT" 2>&1 | tee "$OUT/fixture/run.log"
grep -Fx 'LAB_FIXTURE_TCP_RMS_PASS' "$OUT/fixture/run.log"
grep -Fx 'LAB_FIXTURE_SHAPES_PASS' "$OUT/fixture/run.log"
grep -Fx 'LAB_FIXTURE_TALL_ATLAS_PASS' "$OUT/fixture/run.log"
grep -Fx 'LAB_FIXTURE_UI_PASS' "$OUT/fixture/run.log"
grep -Fx 'LAB_FIXTURE_PIXEL_PASS' "$OUT/fixture/run.log"
grep -E 'LAB_EXIT rc=0 failed=0 frames=[1-9][0-9]* input_overflow=0' "$OUT/fixture/run.log"
python3 - "$OUT/fixture/trace.csv" <<'PY'
import csv,sys,pathlib
p=pathlib.Path(sys.argv[1])
rows=list(csv.DictReader(p.open()))
assert len(rows)>=2
assert int(rows[-1]['paints'])>0 and int(rows[-1]['paint_cpu_ns'])>0
assert int(rows[-1]['draw_calls'])>=4
assert int(rows[-1]['process_cpu_ns'])>int(rows[0]['process_cpu_ns'])
assert 'LabFixture' in pathlib.Path(str(p)+'.edges.tsv').read_text()
assert int(rows[-1]['input_events'])>=1
events=list(csv.DictReader(pathlib.Path(str(p)+'.effects.csv').open()))
assert any(e['operation']=='write' and e['value']=='1' and 'LabFixture$Probe.paint' in e['method'] for e in events), events
assert any(e['operation']=='read' and e['value']=='1' and 'LabFixture$Probe.paint' in e['method'] for e in events), events
assert all(e['lost_total']=='0' for e in events)
assert int(rows[-1]['draw_calls'])>=9
assert int(rows[-1]['gc_cycles'])>0 and int(rows[-1]['gc_cpu_ns'])>0
assert int(rows[-1]['gc_heap_sample_bytes'])>0
print('DESKTOP_LAB_FIXTURE_PASS')
PY
# Exact same arithmetic, TCP, RMS, UI and pixel assertions in A/B.
# Full-raster both ways; no call graph instrumentation in timing profiles.
for mode in plain logic; do
  python3 "$ROOT/tools/desktop_lab/test_transport.py" "$OUT" "$mode" 2>&1 | tee "$OUT/fixture/run-$mode.log"
  for marker in LOGIC TCP_RMS UI PIXEL SHAPES TALL_ATLAS; do
    grep -Fx "LAB_FIXTURE_${marker}_PASS" "$OUT/fixture/run-$mode.log"
  done
  grep -E 'LAB_EXIT rc=0 failed=0 frames=[1-9][0-9]* input_overflow=0' "$OUT/fixture/run-$mode.log"
done
grep -Fx 'LAB_LOGIC mode=0 plans=0 spans=0 ops=0' "$OUT/fixture/run-plain.log"
grep -E '^LAB_LOGIC mode=1 plans=[1-9][0-9]* spans=[1-9][0-9]* ops=[1-9][0-9]*
 "$OUT/fixture/run-logic.log"
echo DESKTOP_LAB_LOGIC_AB_PASS
