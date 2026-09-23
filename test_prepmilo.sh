#!/bin/bash
# Exercises prepmilo.py's saddle-point guard on the shipped Diels-Alder TS.
# Fails loudly if a second-order saddle gets through without --sosd, or a true
# TS stops getting through.
set -uo pipefail
TOOLS="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
P="$TOOLS/prepmilo.py"
TS="$TOOLS/examples/DA_ts_freq.out"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
cd "$T" || exit 1
fail() { echo "FAIL: $1"; exit 1; }

# 1. one imaginary mode: written, pair picked
"$P" -i "$TS" -o ts >/dev/null 2>&1 || fail "true TS refused"
grep -q '# pairs 1-5 4-6' ts.in || fail "true TS: wrong pairs"

# A second-order saddle: the same output with its second frequency made negative.
python3 - "$TS" <<'PY'
import sys
t = open(sys.argv[1]).read()
i = t.index('Frequencies ---'); line = t[i:t.index('\n', i)]
p = line.split(); p[3] = '-' + p[3]
open('sosd.out', 'w').write(t.replace(line, ' '.join(p), 1))
PY

# 2. two imaginary modes, no flag: refused, nothing written, both modes named
out=$("$P" -i sosd.out -o s1 2>&1); rc=$?
[[ $rc -ne 0 ]] || fail "second-order saddle accepted without --sosd"
[[ ! -e s1.in ]] || fail "refused run still wrote s1.in"
grep -q 'second-order saddle' <<<"$out" || fail "no saddle error: $out"
grep -q -- '--sosd' <<<"$out" || fail "error does not mention --sosd"
[[ $(grep -c '[0-9]i ' <<<"$out") -eq 2 ]] || fail "report does not list both modes"

# 3. --sosd: written, following mode 1, with a warning
out=$("$P" -i sosd.out -o s2 --sosd 2>&1) || fail "--sosd refused"
[[ -s s2.in ]] || fail "--sosd wrote nothing"
grep -q 'WARNING: --sosd' <<<"$out" || fail "--sosd gave no warning"
grep -q 'phase *bring_together 1 5' s2.in || fail "--sosd did not follow mode 1"

echo "PASS: all 3 checks"
