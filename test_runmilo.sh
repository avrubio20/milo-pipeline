#!/bin/bash
# Exercises the generated array script against a stub Milo.
# Fails loudly if the skip-guard, atomic staging, --force, or failure
# archiving stop doing what runmilo.py claims they do.
set -uo pipefail
TOOLS="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
RAW="$TOOLS/runmilo.py"
# Checks 1-26 exercise the Slurm dialect and drive it with SLURM_* variables, so
# the scheduler is pinned rather than auto-detected -- otherwise the suite
# generates UGE scripts on a UGE machine and every member lands on index 1.
R() { "$RAW" --scheduler slurm "$@"; }
# Noted before the suite hides it below: this is the config of the installation
# you are testing, and it is the best clue to where a real Milo lives.
REAL_CONF="${MILO_CONF:-$HOME/.milo.conf}"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
# An installed config must not reach in and change what gets generated.
export MILO_CONF="$T/absent.conf"
cd "$T" || exit 1

# --- stub g16: the generated script refuses to start without Gaussian on
#     PATH, and these checks exercise the script, not Gaussian. Milo itself is
#     what would call it, and Milo here is a stub that does not. ---
mkdir -p fakebin
printf '#!/bin/sh\nexit 0\n' > fakebin/g16
chmod +x fakebin/g16
export PATH="$T/fakebin:$PATH"

# --- stub milo: writes <job_name>.xyz, where job_name comes from stdout fd,
#     exactly like input_parser.py:266-271 ---
mkdir -p fakemilo/milo_1_0_3
cat > fakemilo/milo_1_0_3/__main__.py <<'PY'
import os, sys
name = os.readlink('/proc/self/fd/1').split('/')[-1].split('.')[0]
if os.environ.get('STUB_FAIL'):
    print('### stub failing on purpose'); sys.exit(1)
text = sys.stdin.read()
# Real Milo reseeds from an explicit `random_seed <int>` and prints whatever
# seed it ended up with (input_parser.py:281, 498-502). The stub has to do the
# same, or a backward run's .out would never echo the seed it was given.
import re
m = re.search(r'^\s*random_seed\s+(\d+)', text, re.M)
seed = int(m.group(1)) if m else int.from_bytes(os.urandom(5), 'big')
print('### Input File ---------------------------------------------------')
print(text, end='')
print('### Default Parameters Being Used --------------------------------')
print('### Random Seed --------------------------------------------------')
print(f'  {seed}')
open(f'{name}.xyz', 'w').write('1\n  Step 0: 0.0 fs\nC 0.0 0.0 0.0\n')
open(f'{name}_step.com', 'w').write('gaussian noise\n')
PY
touch fakemilo/milo_1_0_3/__init__.py

# --backward shells out to Milo's own tools/setup_backward.py, so the stub tree
# needs the real one. Where Milo lives is the installation's business, so ask
# the config before guessing; MILO_HOME then serves generation and execution.
mkdir -p fakemilo/milo_1_0_3/tools
# Where a real Milo might be, most specific first: what the caller already
# points at, then the install layout (this suite sits in PREFIX/bin, Milo goes
# in PREFIX/opt), then the config, then the older conventions.
inherited="${MILO_HOME:-}"
configured=$(sed -n 's/^ *milo_home *= *//p' "$REAL_CONF" 2>/dev/null)
for cand in "$inherited" "$TOOLS/../opt/milo-1.0.3" "$configured" \
            "$HOME/Programs/milo" "$HOME/Programs/milo-1.0.3"; do
  [[ -n "$cand" ]] || continue
  if [[ -f "$cand/milo_1_0_3/tools/setup_backward.py" ]]; then
    cp "$cand/milo_1_0_3/tools/setup_backward.py" fakemilo/milo_1_0_3/tools/
    break
  fi
done
# The detail goes first and the verdict last: install_milo.sh --check reports a
# suite by its final line, so that line has to stand on its own.
[[ -f fakemilo/milo_1_0_3/tools/setup_backward.py ]] || {
  echo "Looked in: \$MILO_HOME, $TOOLS/../opt/milo-1.0.3, milo_home in"
  echo "$REAL_CONF, ~/Programs/milo and ~/Programs/milo-1.0.3."
  echo "FAIL: no Milo to borrow setup_backward.py from -- install Milo first"
  exit 1; }
export MILO_HOME="$T/fakemilo"
# Self-contained fixture: runmilo.py only ever reads the $job section and the
# stub Milo ignores the rest, so the suite runs anywhere without a fixture file
# from somebody's machine.
cat > DA_test.in <<'IN'
$job
    gaussian_header         wb97xd/6-31G* int=ultrafine
    program                 gaussian16
    step_size               1.00
    max_steps               50
    temperature             298.15
    phase                   bring_together 1 5
    memory                  8
    processors              8
    random_seed             generate
$end
IN

R DA_test.in --traj 3 --no-submit >/dev/null || exit 1
run() { env SLURM_ARRAY_TASK_ID="$1" SLURM_SUBMIT_DIR="$T" MILO_G16_SETUP=/dev/null \
        MILO_HOME="$T/fakemilo" MILO_SCRATCH="$T/scratch" \
        ${2:+STUB_FAIL=1} bash DA_test_milo.sh; }

fail() { echo "FAIL: $1"; exit 1; }

# 1. fresh member succeeds and publishes
out=$(run 1); rc=$?
[[ $rc -eq 0 ]] || fail "fresh run exited $rc"
[[ -s results/DA_test_001/DA_test_001.out && -s results/DA_test_001/DA_test_001.xyz ]] || fail "member 001 not published"
grep -q 'exit_code: 0' <<<"$out" || fail "no success footer"
grep -q 'task 1 of 3' <<<"$out" || fail "array META line wrong"
ls results/DA_test_001/.DA_test_001.*.part >/dev/null 2>&1 && fail "temp staging file left behind"

# 2. distinct members coexist
run 2 >/dev/null; [[ -s results/DA_test_002/DA_test_002.out ]] || fail "member 002 not published"

# 3. re-running a finished member skips instead of clobbering
before=$(md5sum results/DA_test_001/DA_test_001.out)
out=$(run 1); rc=$?
[[ $rc -eq 0 ]] || fail "skip path exited $rc"
grep -q '^SKIP:' <<<"$out" || fail "finished member did not skip"
[[ "$(md5sum results/DA_test_001/DA_test_001.out)" == "$before" ]] || fail "skip path overwrote results"

# 4. --rerun re-runs it (--force alone must not; see check 8)
R DA_test.in --traj 3 --no-submit --rerun >/dev/null
out=$(run 1); rc=$?
[[ $rc -eq 0 ]] || fail "--rerun run exited $rc"
grep -q '^SKIP:' <<<"$out" && fail "--rerun still skipped"
[[ "$(md5sum results/DA_test_001/DA_test_001.out)" == "$before" ]] && fail "--rerun did not rewrite results"

# 5. failure archives diagnostics, keeps a footer, does not publish
out=$(run 3 fail); rc=$?
[[ $rc -eq 1 ]] || fail "failing run exited $rc, expected 1"
[[ -e results/DA_test_003/DA_test_003.out ]] && fail "failed member published to results/"
grep -q 'exit_code: 1' <<<"$out" || fail "no failure footer"
ls results.failed/DA_test_003.*/DA_test_003_gaussian_com_log.tar.gz >/dev/null 2>&1 \
  || fail "failure diagnostics not archived"

# 6. a second failure preserves the first attempt's evidence
sleep 1; run 3 fail >/dev/null
[[ $(ls -d results.failed/DA_test_003.* | wc -l) -eq 2 ]] \
  || fail "second failure clobbered the first attempt"


# 7. an explicitly seeded input is refused for an ensemble (all members would be
#    the same trajectory) but still allowed for a single deliberate rerun
sed -E 's/^([[:space:]]*random_seed[[:space:]]+).*/\1 12345/' DA_test.in > DA_seeded.in
R DA_seeded.in --traj 10 --no-submit >/dev/null 2>err.txt && \
  fail "explicitly seeded input accepted for a 10-member ensemble"
grep -q 'identical trajectory' err.txt || fail "seed rejection lacked an explanation"
R DA_seeded.in --traj 1 --no-submit >/dev/null 2>&1 \
  || fail "explicitly seeded input rejected for --traj 1"

# 8. --force regenerates the script without destroying finished results
before=$(md5sum results/DA_test_001/DA_test_001.out)
R DA_test.in --traj 3 --no-submit --force >/dev/null 2>&1
out=$(run 1)
grep -q '^SKIP:' <<<"$out" || fail "--force alone re-ran a finished member"
[[ "$(md5sum results/DA_test_001/DA_test_001.out)" == "$before" ]] || fail "--force destroyed results"

# 9. --rerun does replace them -- not merely decline to skip
R DA_test.in --traj 3 --no-submit --rerun >/dev/null 2>&1
before=$(md5sum < results/DA_test_001/DA_test_001.out)
out=$(run 1)
grep -q '^SKIP:' <<<"$out" && fail "--rerun still skipped"
[[ "$(md5sum < results/DA_test_001/DA_test_001.out)" == "$before" ]] \
  && fail "--rerun left the old result in place"

# 10. back-to-back failures never collide, even within the same second.
#     Counted before and after: earlier checks already left directories here, so
#     an absolute threshold would pass even if these two runs archived nothing.
R DA_test.in --traj 3 --no-submit --force >/dev/null 2>&1
before=$(ls -d results.failed/DA_test_003.* 2>/dev/null | wc -l)
run 3 fail >/dev/null; run 3 fail >/dev/null
after=$(ls -d results.failed/DA_test_003.* 2>/dev/null | wc -l)
[[ $((after - before)) -eq 2 ]] \
  || fail "same-second failures collided ($before -> $after, expected +2)"

# 11. a resource override actually reaches the input Gaussian will read
R DA_test.in --traj 1 --cpus 3 --mem 5 --no-submit --rerun >/dev/null 2>&1
out=$(run 1); rc=$?
[[ $rc -eq 0 ]] || fail "override run exited $rc"
grep -q 'resources:   3 cpus, 5 GB' <<<"$out" || fail "override not reported in META"
grep -qE '^#SBATCH --nodes=1 --ntasks=1 --cpus-per-task=3' DA_test_milo.sh \
  || fail "Slurm request did not follow --cpus"

# 12. scratch is a job-unique child, so members cannot share a directory
grep -q 'SCRATCH="$SCRATCH_ROOT/milo_' DA_test_milo.sh \
  || fail "scratch is not a job-unique child of the root"

# 13. joblogs/ exists before sbatch would be called (Slurm opens it first)
rm -rf joblogs
R DA_test.in --traj 1 --no-submit --force >/dev/null 2>&1
[[ -d joblogs ]] || fail "joblogs/ not created by the submitter"

# 14. one bad input in a batch submits nothing at all
rm -f DA_other_milo.sh
cp DA_test.in DA_other.in
R DA_other.in DOES_NOT_EXIST.in --traj 1 --no-submit >/dev/null 2>&1 \
  && fail "batch with a missing input succeeded"
[[ -e DA_other_milo.sh ]] && fail "partial batch wrote a script before validating all inputs"

# 15. each trajectory lands in its own directory
[[ -d results/DA_test_001 && -d results/DA_test_002 ]] || fail "no per-member directories"
[[ -e results/DA_test_001.out ]] && fail "member published flat instead of in its folder"

# --- backward half-trajectories ---

# 16. --backward is sized from results/, so it refuses --traj and refuses a base
#     that has not run forward yet
R DA_test.in --backward --traj 3 --no-submit >/dev/null 2>&1 \
  && fail "--backward accepted --traj"
R DA_other.in --backward --no-submit >/dev/null 2>err.txt \
  && fail "--backward accepted a base with no finished members"
grep -q 'no finished members' err.txt || fail "--backward rejection lacked an explanation"

# 17. --dry-run must not write the reversed inputs it is only describing
rm -rf backward
R DA_test.in --backward --dry-run >/dev/null 2>&1 \
  || fail "--backward --dry-run failed"
[[ -e backward ]] && fail "--dry-run wrote backward/ inputs"

# 18. the array covers exactly the finished members, holes and all: 1, 2 and 4
#     finished, 3 only ever failed
run 4 >/dev/null; [[ -s results/DA_test_004/DA_test_004.out ]] || fail "member 004 not published"
fwd_sum=$(md5sum < DA_test_milo.sh)
R DA_test.in --backward --no-submit >/dev/null 2>&1 \
  || fail "--backward failed on finished members"
grep -q '^#SBATCH --array=1,2,4$' DA_test_rev_milo.sh \
  || fail "backward array is not the sparse list of finished members"
[[ "$(md5sum < DA_test_milo.sh)" == "$fwd_sum" ]] || fail "backward run rewrote the forward script"

# 19. one reversed input per finished member, phase actually flipped in the
#     directive itself, each carrying its OWN member's seed
[[ -e backward/DA_test_003_rev.in ]] && fail "reversed input built from a failed member"
for m in 001 002 004; do
  f=backward/DA_test_${m}_rev.in
  [[ -s $f ]] || fail "reversed input $f not written"
  grep -qE '^[[:space:]]*phase[[:space:]]+push_apart' $f \
    || fail "$f did not flip the phase directive"
  grep -qE '^[[:space:]]*phase[[:space:]]+bring_together' $f \
    && fail "$f still carries the forward phase directive"
  seed=$(grep -A1 '### Random Seed' results/DA_test_$m/DA_test_$m.out | tail -1 | tr -d ' ')
  [[ $seed =~ ^[0-9]+$ ]] || fail "could not read member $m's forward seed"
  grep -qE "^[[:space:]]*random_seed[[:space:]]+$seed\$" $f \
    || fail "$f does not replay member $m's own seed"
done

# 20. a backward member runs, reads the REVERSED input (the stub echoes its
#     stdin), and publishes to its own directory
env SLURM_ARRAY_TASK_ID=1 SLURM_SUBMIT_DIR="$T" MILO_HOME="$T/fakemilo" \
    MILO_SCRATCH="$T/scratch" bash DA_test_rev_milo.sh >/dev/null 2>&1 || fail "backward member exited nonzero"
[[ -s results/DA_test_001_rev/DA_test_001_rev.out ]] \
  || fail "backward member not published to its own directory"
grep -qE '^[[:space:]]*phase[[:space:]]+push_apart' results/DA_test_001_rev/DA_test_001_rev.out \
  || fail "backward member ran an input that was not the reversed one"

# 21. re-running a backward member that is still the partner of the forward
#     result on disk skips, as before
out=$(env SLURM_ARRAY_TASK_ID=1 SLURM_SUBMIT_DIR="$T" MILO_HOME="$T/fakemilo" \
      MILO_SCRATCH="$T/scratch" bash DA_test_rev_milo.sh)
grep -q '^SKIP:' <<<"$out" || fail "a matching backward result did not skip"

# 22. but once the forward member is re-run, its old reverse result belongs to a
#     trajectory that no longer exists -- refuse rather than skip it
R DA_test.in --traj 4 --no-submit --rerun >/dev/null 2>&1
run 1 >/dev/null
R DA_test.in --backward --no-submit --force >/dev/null 2>&1 \
  || fail "--backward failed after the forward member was re-run"
out=$(env SLURM_ARRAY_TASK_ID=1 SLURM_SUBMIT_DIR="$T" MILO_HOME="$T/fakemilo" \
      MILO_SCRATCH="$T/scratch" bash DA_test_rev_milo.sh 2>&1); rc=$?
[[ $rc -eq 0 ]] && fail "stale backward result was accepted after a forward re-run"
grep -q 'was re-run' <<<"$out" || fail "stale backward result rejected without an explanation"

# 23. a phase with no opposite is refused before anything is generated --
#     setup_backward.py would leave `random` (or an upper-case value) in place
#     and only print a warning
sed -E 's/^([[:space:]]*phase[[:space:]]+).*/\1random/' DA_test.in > DA_rand.in
mkdir -p results/DA_rand_001
cp results/DA_test_002/DA_test_002.out results/DA_rand_001/DA_rand_001.out
cp results/DA_test_002/DA_test_002.xyz results/DA_rand_001/DA_rand_001.xyz
rm -rf backward
R DA_rand.in --backward --no-submit >/dev/null 2>err.txt \
  && fail "--backward accepted `phase random`"
grep -q 'no reverse' err.txt || fail "phase rejection lacked an explanation"
[[ -e backward ]] && fail "refused --backward still wrote reversed inputs"

# 24. a forward .out truncated before its seed makes setup_backward.py write
#     `random_seed None`, which would submit and only fail inside Milo
mkdir -p results/DA_trunc_001
sed '/### Random Seed/,$d' results/DA_test_002/DA_test_002.out > results/DA_trunc_001/DA_trunc_001.out
cp results/DA_test_002/DA_test_002.xyz results/DA_trunc_001/DA_trunc_001.xyz
cp DA_test.in DA_trunc.in
rm -rf backward
R DA_trunc.in --backward --no-submit >/dev/null 2>err.txt \
  && fail "--backward accepted an input with no usable seed"
grep -q 'random_seed' err.txt || fail "seed rejection lacked an explanation"

# 25. --force grows an ensemble, so the members already on disk must have run
#     the same input. Editing the .in and re-submitting would otherwise mix two
#     specifications into one ensemble.
rm -rf results results.failed backward DA_test_rev_milo.sh
R DA_test.in --traj 3 --no-submit --force >/dev/null 2>&1
run 1 >/dev/null; run 2 >/dev/null
sed -i -E 's/^([[:space:]]*max_steps[[:space:]]+).*/\1500/' DA_test.in
R DA_test.in --traj 3 --no-submit --force >/dev/null 2>err.txt \
  && fail "extended an ensemble whose members ran a different input"
grep -q 'ran a different input' err.txt || fail "input mismatch lacked an explanation"
# --rerun is the documented way past it, since it replaces them
R DA_test.in --traj 3 --no-submit --rerun >/dev/null 2>&1 \
  || fail "--rerun refused to replace members that ran a different input"

# 26. a resource override is not a different input: --cpus/--mem are rewritten
#     in scratch on every run, so they must not look like a changed spec
sed -i -E 's/^([[:space:]]*max_steps[[:space:]]+).*/\150/' DA_test.in
rm -rf results
R DA_test.in --traj 3 --no-submit --force >/dev/null 2>&1
run 1 >/dev/null
R DA_test.in --traj 3 --cpus 3 --mem 5 --no-submit --force \
  >/dev/null 2>err.txt || fail "a --cpus/--mem override was treated as a changed input"
grep -q 'ran a different input' err.txt && fail "resource override flagged as a spec change"

# --- Hoffman2 / UGE dialect ---

# 27. UGE emits SGE directives, not Slurm ones, in the house idiom:
#     h_data is per slot and h_vmem per slot x slots, times in seconds, and the
#     USR1 warning lands before the hard limit
rm -rf results results.failed backward
"$RAW" DA_test.in --scheduler uge --traj 3 -p 8 -m 12 -t 4 \
  --array-limit 2 --no-submit --force >/dev/null 2>&1 || fail "hoffman2 generation failed"
grep -q '^#SBATCH' DA_test_milo.sh && fail "Slurm directives leaked into a UGE script"
grep -q '^#!/bin/bash -l$' DA_test_milo.sh || fail "UGE script is not a login shell"
grep -q '^#\$ -t 1-3$' DA_test_milo.sh || fail "no UGE array range"
grep -q '^#\$ -tc 2$' DA_test_milo.sh || fail "--array-limit did not become -tc"
grep -q '^#\$ -pe shared\* 8$' DA_test_milo.sh || fail "no parallel environment"
grep -q '^#\$ -notify$' DA_test_milo.sh || fail "no -notify, so no USR1 warning"
grep -q 'h_data=2048M,h_vmem=16384M' DA_test_milo.sh \
  || fail "h_data must be per slot and h_vmem per slot x slots: $(grep '^#\$ -l' DA_test_milo.sh)"
grep -q 'h_rt=14400,s_rt=14100' DA_test_milo.sh || fail "s_rt is not 5 min before h_rt"
grep -q 'trap _kill_child INT TERM USR1' DA_test_milo.sh \
  || fail "UGE's USR1 walltime warning is not trapped"

# 28. and a member actually runs under SGE's variables -- a UGE script ignores
#     the Slurm ones entirely, which is why run() cannot drive it
uge() { env SGE_TASK_ID="$1" JOB_ID=99999 SGE_O_WORKDIR="$T" \
        MILO_HOME="$T/fakemilo" MILO_SCRATCH="$T/scratch" \
        bash "${2:-DA_test_milo.sh}"; }
uge 2 >/dev/null 2>&1 || fail "UGE member exited nonzero"
[[ -s results/DA_test_002/DA_test_002.out ]] || fail "UGE member did not publish"

# 29. UGE's -t takes one range, not a comma list, so a roster with a hole
#     submits the range and the members outside it step aside
uge 1 >/dev/null 2>&1; uge 3 >/dev/null 2>&1
rm -rf results/DA_test_002                     # 1 and 3 finished, 2 did not
"$RAW" DA_test.in --scheduler uge --backward --no-submit --force >/dev/null 2>&1 \
  || fail "hoffman2 --backward generation failed"
grep -qE '^#\$ -t 1-3$' DA_test_rev_milo.sh || fail "sparse roster did not become a range"
grep -q 'MEMBERS="1 3"' DA_test_rev_milo.sh || fail "no roster guard for the hole"
out=$(uge 2 DA_test_rev_milo.sh)
grep -q 'not part of this ensemble' <<<"$out" || fail "member outside the roster ran anyway"
[[ -e results/DA_test_002_rev ]] && fail "member outside the roster published results"

# 30. a wrong MILO_HOME says so at once, instead of a python import traceback
#     ten minutes into a queued job. Member 9 has no results, so this reaches
#     the environment setup instead of stopping at the skip guard.
R DA_test.in --traj 9 --no-submit --force >/dev/null 2>&1
out=$(env SLURM_ARRAY_TASK_ID=9 SLURM_SUBMIT_DIR="$T" MILO_HOME="$T/not-milo" \
      MILO_SCRATCH="$T/scratch" bash DA_test_milo.sh 2>&1); rc=$?
[[ $rc -ne 0 ]] || fail "a missing Milo install still exited 0"
grep -q "no Milo at $T/not-milo" <<<"$out" || fail "missing Milo not named: $out"

# 31. no Gaussian on PATH is refused up front, not discovered mid-run.
#     Member 12 has no results, so this gets past the skip guard.
R DA_test.in --traj 12 --no-submit --force >/dev/null 2>&1 || fail "generation failed"
out=$(env SLURM_ARRAY_TASK_ID=12 SLURM_SUBMIT_DIR="$T" MILO_HOME="$T/fakemilo" \
      MILO_SCRATCH="$T/scratch" PATH="/usr/bin:/bin" bash DA_test_milo.sh 2>&1); rc=$?
[[ $rc -ne 0 ]] || fail "script ran with no g16 on PATH"
grep -q 'g16 is not on PATH' <<<"$out" || fail "no g16 error: $out"

echo "PASS: all 31 checks"
