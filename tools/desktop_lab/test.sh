#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
OUT=$(realpath "$1")
mkdir -p "$OUT/fixture/classes" "$OUT/fixture/save"
javac --release 8 -cp "$OUT/jars/j2me_api.jar" -d "$OUT/fixture/classes" "$ROOT/tools/desktop_lab/LabFixture.java"
printf 'Manifest-Version: 1.0\nMIDlet-Name: LabFixture\nMIDlet-Version: 1.0\nMIDlet-Vendor: JarBox\nMIDlet-1: LabFixture,,LabFixture\n\n' > "$OUT/fixture/manifest"
jar cfm "$OUT/fixture/fixture.jar" "$OUT/fixture/manifest" -C "$OUT/fixture/classes" .
SDL_VIDEODRIVER=dummy JARBOX_LAB_UI_FIXTURE=1 timeout 90 "$OUT/jarbox-lab" "$OUT/jars/minijvm_rt.jar" "$OUT/jars/j2me_api.jar" "$OUT/fixture/fixture.jar" "$OUT/fixture/save" "$OUT/fixture/trace.csv" 240 320 graph 2>&1 | tee "$OUT/fixture/run.log"
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
print('DESKTOP_LAB_FIXTURE_PASS')
PY
