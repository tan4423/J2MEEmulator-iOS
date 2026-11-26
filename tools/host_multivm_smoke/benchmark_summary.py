"""Summarize a complete 4x4 real MiniJVM host benchmark; never promote automatically."""
import json
import sys
from pathlib import Path
from statistics import median

NAMES = ("baseline", "array", "char", "both")
FIELDS = ("round", "mask", "thread_ns", "process_ns", "array", "char", "gc")


def analyze(log):
    rows = {}
    for line in log.splitlines():
        if not line.startswith("bench "):
            continue
        parts = line.split()[1:]
        if len(parts) != len(FIELDS):
            raise ValueError("bad benchmark row")
        fields = {}
        for part in parts:
            k, sep, v = part.partition("=")
            if not sep or k not in FIELDS or k in fields or not v.isascii() or not v.isdecimal():
                raise ValueError("invalid field")
            fields[k] = int(v)
        r, m = fields["round"], fields["mask"]
        if r not in range(4) or m not in range(4) or (r, m) in rows:
            raise ValueError("unexpected or duplicate round/mask")
        if not fields["thread_ns"] or not fields["process_ns"] or not fields["gc"]:
            raise ValueError("clock or GC missing")
        for bit, key in ((1, "array"), (2, "char")):
            if (m & bit and fields[key] < 64) or (not m & bit and fields[key]):
                raise ValueError("candidate not exercised or contaminated baseline")
        rows[r, m] = fields
    if len(rows) != 16 or "intrinsic_bench: PASS" not in log.splitlines():
        raise ValueError("incomplete benchmark")
    result = {}
    for m, name in enumerate(NAMES):
        d = {}
        for k in ("thread_ns", "process_ns"):
            values = [rows[r, m][k] for r in range(4)]
            ratios = [rows[r, m][k] / rows[r, 0][k] for r in range(4)]
            d[k.replace("_ns", "_median_ms")] = median(values) / 1e6
            d[k.replace("_ns", "_paired_ratio")] = ratios
            d[k.replace("_ns", "_paired_median_change_pct")] = 100 * (median(ratios) - 1)
        result[name] = d
    return {"legs": result, "limitations": [
        "host x86/Linux, O2, no sanitizers; no iPhone or game CPU/power claim",
        "call_main interval includes startup and fixture validation; thread CPU may not include other Java threads",
        "process CPU includes GC and other process work, not just intrinsic calls",
        "same binary host-only mask; no automatic promotion based on timings"]}


if __name__ == "__main__":
    print(json.dumps(analyze(Path(sys.argv[1]).read_text()), indent=2))
