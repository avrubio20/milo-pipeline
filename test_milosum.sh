#!/bin/bash
# Exercises milosum.py against synthetic ensembles whose right answer is known
# by construction. Fails loudly if the commitment criterion, the pairing rule,
# or the completeness refusal stop doing what milosum.py claims they do.
set -uo pipefail
# The tools are wherever this suite is: ~/bin on the workstation and
# Expanse, ~/Scripts on Hoffman2.
TOOLS="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
MS="$TOOLS/milosum.py"

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
cd "$T" || exit 1

fail() { echo "FAIL: $1"; exit 1; }

# --- a 4-atom stand-in; bonds 1-3 and 2-4 are the two "forming" bonds ---
cat > make.py <<'PY'
import re
import sys
from pathlib import Path

def write(name, series, flat=False, normal=True, seed=None, crash=False):
    d = Path('results') if flat else Path('results') / name
    d.mkdir(parents=True, exist_ok=True)
    xyz = [f'4\n  Step {i}: {float(i)} fs\nC 0.0 0.0 0.0\nC 0.0 20.0 0.0\n'
           f'C {a:.3f} 0.0 0.0\nC 0.0 {20.0 + b:.3f} 0.0'
           for i, (a, b) in enumerate(series)]
    (d / f'{name}.xyz').write_text('\n'.join(xyz) + '\n')
    if seed is None:  # halves of one trajectory share a seed, as Milo does
        seed = 100000 + int(re.search(r'_(\d+)', name).group(1))
    tail = 'Normal termination.\n'
    if crash:   # a reused .out: a good run, then a crashed one after it
        tail += 'Step 51\n' * 6 + 'ERROR: killed\n'
    elif not normal:
        tail = 'killed\n'
    (d / f'{name}.out').write_text(f'### Random Seed ---\n  {seed}\n\n' + tail)

def ramp(start, end, n=40):
    return [start + (end - start) * i / (n - 1) for i in range(n)]

# product: both bonds close in, then ring back up well past --formed. The last
# frame of the first bond is 1.84 A -- a last-frame test would call this a miss.
RING = ramp(2.26, 1.28, 25) + ramp(1.30, 1.84, 15)
PRODUCT = list(zip(RING, ramp(2.26, 1.60)))
REACTANT = list(zip(ramp(2.26, 3.4), ramp(2.26, 3.6)))
STEPWISE = list(zip(RING, ramp(2.26, 3.6)))
UNDECIDED = list(zip(ramp(2.26, 2.0), ramp(2.26, 2.1)))
# A product whose two bonds form ~35 fs apart, against ~20 fs for PRODUCT: an
# unmistakable outlier in any gap-time summary that wrongly includes it.
LATE = list(zip(ramp(2.26, 1.30, 4) + ramp(1.31, 1.50, 36),
                ramp(2.26, 1.72, 37) + ramp(1.69, 1.60, 3)))
# recrossing: forms, then comes all the way back apart
RECROSS = list(zip(ramp(2.26, 1.3, 15) + ramp(1.4, 3.5, 25),
                   ramp(2.26, 1.3, 15) + ramp(1.4, 3.6, 25)))

for spec in sys.argv[1:]:
    name, kind = spec.split('=')
    seed = None
    if ':' in kind:                       # name=kind:seed pins the seed
        kind, seed = kind.split(':')
        seed = int(seed)
    crash = kind.endswith('@crash')
    kind = kind[:-len('@crash')] if crash else kind
    flat = kind.endswith('@flat')
    # not str.removesuffix: Expanse's conda base is python 3.8
    kind = kind[:-len('@flat')] if flat else kind
    write(name, globals()[kind.upper()], flat=flat, seed=seed, crash=crash)
PY

cat > DA.in <<'IN'
$job
    processors              4
    memory                  4
    phase                   bring_together 1 3
    random_seed             generate
$end
IN
manifest() { printf '#!/bin/bash\n#SBATCH --array=%s\n' "$1" > "$2"; }

# 1. no manifest and no --expect: refuse rather than summarise the survivors
python3 make.py DA_001=product >/dev/null
"$MS" DA.in --pairs 1-3 2-4 >/dev/null 2>err.txt && fail "summarised with no manifest"
grep -q -- '--expect' err.txt || fail "missing-manifest error did not name --expect"

# 2. the ensemble size comes from the array line, so a missing member is counted
manifest '1-4' DA_milo.sh
out=$("$MS" DA.in --pairs 1-3 2-4 2>err.txt); rc=$?
[[ $rc -eq 1 ]] || fail "incomplete ensemble did not exit 1"
grep -q '1/4 complete (25%)' <<<"$out" || fail "did not count the expected members: $out"
grep -q 'REFUSING' err.txt || fail "reported a ratio below --min-complete"
# a refusal that still prints the ratio is not a refusal
grep -qE '^  [a-z>-]+ +[0-9]+ +[0-9.]+%' <<<"$out" \
  && fail "refused run still printed a branching ratio: $out"
grep -q '(fraction withheld)' <<<"$out" || fail "refused run did not say the fraction was withheld"
[[ "$("$MS" DA.in --pairs 1-3 2-4 --json 2>/dev/null | python3 -c \
   'import json,sys; print(json.load(sys.stdin)["fractions"])')" == '{}' ]] \
  || fail "refused run still published fractions in --json"

# 3. each terminus is named from the trace, and a failed member is distinguished
#    from one that never ran
python3 make.py DA_002=reactant DA_003=stepwise >/dev/null
mkdir -p results.failed/DA_004.abc123
out=$("$MS" DA.in --pairs 1-3 2-4 --min-complete 0.5 2>/dev/null); rc=$?
[[ $rc -eq 0 ]] || fail "complete-enough ensemble exited $rc"
grep -q 'failed: 1' <<<"$out" || fail "failed member not reported as failed: $out"
for k in product reactant stepwise; do
  grep -qE "^  $k +1 +33.3%" <<<"$out" || fail "$k not counted once: $out"
done

# 4. the ringing product is the reason for hysteresis: it bottoms out at 1.28 A
#    and ends at 1.84 A, above --formed, and is still a product
grep -q 'gap time' <<<"$out" || fail "no gap time for the product member"

# 5. a bond that forms and then comes apart is a recrossing, and lands in the
#    terminus it actually ended in
rm -rf results results.failed
python3 make.py DA_001=recross DA_002=product DA_003=product DA_004=product >/dev/null
out=$("$MS" DA.in --pairs 1-3 2-4 2>/dev/null)
grep -q 'recrossed: members \[1\]' <<<"$out" || fail "recrossing not detected: $out"
grep -qE '^  reactant +1' <<<"$out" || fail "recrossed member not counted as reactant: $out"

# 6. undecided is its own class -- never folded into product
rm -rf results
python3 make.py DA_001=undecided DA_002=product DA_003=product DA_004=product >/dev/null
out=$("$MS" DA.in --pairs 1-3 2-4 2>/dev/null)
grep -qE '^  undecided +1' <<<"$out" || fail "undecided member not reported: $out"

# 7. with backward halves, a pair is ONE sample: 4 forward + 4 reverse is n=4,
#    and the outcome is written reverse->forward
rm -rf results
python3 make.py DA_001=product DA_002=product DA_003=product DA_004=product \
                DA_001_rev=reactant DA_002_rev=reactant DA_003_rev=reactant \
                DA_004_rev=reactant >/dev/null
manifest '1-4' DA_rev_milo.sh
out=$("$MS" DA.in --pairs 1-3 2-4 2>/dev/null)
grep -q 'one sample = one forward+backward pair' <<<"$out" \
  || fail "pairs not treated as the sample unit: $out"
grep -qE '^  reactant->product +4 +100.0%' <<<"$out" \
  || fail "paired outcome not reported reverse->forward: $out"
n=$("$MS" DA.in --pairs 1-3 2-4 --json | python3 -c 'import json,sys; print(json.load(sys.stdin)["complete"])')
[[ "$n" == 4 ]] || fail "sample count was $n, not 4 -- halves counted as samples"

# 8. an unfinished backward half makes the whole pair incomplete
rm -rf results/DA_004_rev
out=$("$MS" DA.in --pairs 1-3 2-4 --min-complete 0.5 2>/dev/null)
grep -q '3/4 complete' <<<"$out" || fail "missing backward half did not spoil the pair: $out"

# 9. the CI is over samples, not halves. 4 complete pairs must give the Wilson
#    interval at n=4 (lower bound 0.510); counting the 8 halves as samples would
#    report 0.676 and claim an ensemble twice the size of the one that was run.
python3 make.py DA_004_rev=reactant >/dev/null
lo=$("$MS" DA.in --pairs 1-3 2-4 --json | python3 -c \
  'import json,sys; print("%.3f" % json.load(sys.stdin)["fractions"]["reactant->product"]["ci95"][0])')
[[ "$lo" == "0.510" ]] || fail "95% CI lower bound was $lo, expected 0.510 (Wilson at n=4)"

# 10. the pre-2026-09-12 flat layout is still readable
rm -rf results DA_rev_milo.sh
python3 make.py DA_001=product@flat DA_002=product@flat DA_003=product@flat \
                DA_004=product@flat >/dev/null
out=$("$MS" DA.in --pairs 1-3 2-4 2>/dev/null)
grep -q '4/4 complete (100%)' <<<"$out" || fail "flat results/ layout not read: $out"

# 11. overlapping thresholds are refused before anything is read: inside the
#     overlap the committed state would depend on frame parity, not chemistry
"$MS" DA.in --pairs 1-3 2-4 --formed 3.0 --broken 1.7 >/dev/null 2>err.txt \
  && fail "accepted --formed above --broken"
grep -q 'hysteresis' err.txt || fail "threshold rejection lacked an explanation"

# 12. a .out whose successful termination is followed by a crash is incomplete
rm -rf results
python3 make.py DA_001=product@crash DA_002=product DA_003=product DA_004=product >/dev/null
out=$("$MS" DA.in --pairs 1-3 2-4 --min-complete 0.5 2>/dev/null)
grep -q '3/4 complete' <<<"$out" || fail "reused .out counted as complete: $out"

# 13. reverse halves on disk with no reverse manifest: the sample unit would
#     silently revert to single trajectories
rm -rf results
python3 make.py DA_001=product DA_002=product DA_003=product DA_004=product \
                DA_001_rev=reactant >/dev/null
"$MS" DA.in --pairs 1-3 2-4 >/dev/null 2>err.txt \
  && fail "ignored reverse results that had no manifest"
grep -q 'forward-only' err.txt || fail "orphan-reverse error did not explain itself"

# 14. a reverse manifest that is not the same ensemble as the forward one
manifest '1-5' DA_rev_milo.sh
python3 make.py DA_002_rev=reactant DA_003_rev=reactant DA_004_rev=reactant \
                DA_005_rev=reactant >/dev/null
"$MS" DA.in --pairs 1-3 2-4 >/dev/null 2>err.txt \
  && fail "paired two different ensembles"
grep -q 'reverse member(s) \[5\]' err.txt || fail "set mismatch did not name the extra member"

# 14b. but a reverse ensemble that is a SUBSET is the normal case: --backward
#      only builds halves for members that finished, so the rest are just
#      incomplete samples, not an error
rm -rf results/DA_005_rev; manifest '1-3' DA_rev_milo.sh
out=$("$MS" DA.in --pairs 1-3 2-4 --min-complete 0.5 2>/dev/null) \
  || fail "a reverse subset was refused instead of counted as incomplete"
grep -q '3/4 complete' <<<"$out" || fail "unpaired forward member not counted incomplete: $out"
manifest '1-4' DA_rev_milo.sh

# 15. filename indices are not evidence: a reverse half that ran a different
#     seed is not the partner of its forward half
rm -rf results/DA_005_rev; manifest '1-4' DA_rev_milo.sh
python3 make.py DA_003_rev=reactant:999999 >/dev/null
out=$("$MS" DA.in --pairs 1-3 2-4 --min-complete 0.5 2>err.txt)
grep -q 'seed-mismatch: 1' <<<"$out" || fail "mis-seeded pair not flagged: $out"
grep -q 'not two halves of one trajectory' err.txt || fail "no warning for the mis-seeded pair"
grep -q '3/4 complete' <<<"$out" || fail "mis-seeded pair still counted as a sample: $out"

# 16. gap times describe the same population as the ratio: member 4's forward
#     half forms its bonds ~35 fs apart (ordinary products: ~20), but its pair
#     is incomplete, so that outlier must not reach the summary
rm -rf results results.failed
python3 make.py DA_001=product DA_002=product DA_003=product DA_004=late \
                DA_001_rev=reactant DA_002_rev=reactant DA_003_rev=reactant >/dev/null
out=$("$MS" DA.in --pairs 1-3 2-4 --min-complete 0.5 2>/dev/null)
grep -q 'gap time' <<<"$out" || fail "no gap time reported: $out"
worst=$("$MS" DA.in --pairs 1-3 2-4 --min-complete 0.5 --json 2>/dev/null \
        | python3 -c 'import json,sys; print(json.load(sys.stdin)["gap_fs"]["max"])')
[[ ${worst%.*} -lt 25 ]] \
  || fail "gap time included member 4 (max $worst fs), which is not in the ratio"

# 17. a channel nobody saw still has an upper bound: 0 of 4 stepwise is
#     [0.0%, 49.0%], not silence
rm -rf results DA_rev_milo.sh
python3 make.py DA_001=product DA_002=product DA_003=product DA_004=product >/dev/null
out=$("$MS" DA.in --pairs 1-3 2-4 2>/dev/null)
grep -qE '^  stepwise +0 +0.0% +\[0.0%, 49.0%\]' <<<"$out" \
  || fail "unobserved channel reported without an upper bound: $out"

# 18. members on disk that the manifest does not list are reported, not
#     silently ignored -- a shrunk --traj leaves exactly this behind
rm -rf results
python3 make.py DA_001=product DA_002=product DA_003=product DA_004=product \
                DA_007=product >/dev/null
out=$("$MS" DA.in --pairs 1-3 2-4 2>/dev/null)
grep -q 'outside the ensemble: 1 member' <<<"$out" \
  || fail "member outside the manifest not reported: $out"
grep -q '4/4 complete' <<<"$out" || fail "stray member changed the denominator: $out"

# 19. a pair naming an atom that is not in the trajectory is inventory, not a
#     traceback -- wrong --pairs, or a truncated frame
rm -rf results
python3 make.py DA_001=product DA_002=product DA_003=product DA_004=product >/dev/null
out=$("$MS" DA.in --pairs 1-3 2-9 --min-complete 0.1 2>err.txt); rc=$?
[[ $rc -le 1 ]] || fail "out-of-range pair crashed milosum (exit $rc)"
grep -q 'malformed: 4' <<<"$out" || fail "out-of-range pair not reported as malformed: $out"
grep -q 'atom(s), but the bonds to follow' err.txt || fail "no warning naming the bad pair"
grep -q 'Traceback' err.txt && fail "milosum raised instead of reporting"

echo "PASS: all 19 checks"
