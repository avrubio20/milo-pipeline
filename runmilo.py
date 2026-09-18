#!/usr/bin/env python3
"""
runmilo.py

Submit a Milo trajectory ensemble as a single Slurm job array, with
post-processing.

Writes <base>_milo.sh next to <base>.in and submits it as an array of --traj
members. Every member runs the *same* input file; Milo draws its own 40-bit
seed from os.urandom at run time and records it in the .out, so the members are
independent trajectories without needing one input file each.

    runmilo.py DA_fwd.in                      # 1 trajectory -- the test run
    runmilo.py DA_fwd.in --traj 100           # 100 trajectories, one array
    runmilo.py DA_fwd.in --traj 100 --force   # re-run members already finished
    runmilo.py DA_fwd.in --pairs 1-5 4-6      # plot both forming bonds
    runmilo.py DA_fwd.in --dry-run            # print the script, submit nothing

After a forward ensemble finishes, --backward runs the other half of each
trajectory: setup_backward.py reverses the phase and stamps the forward
member's seed, so the reverse replays the same initial conditions with the sign
of mode 0 flipped. Forward member NNN and backward member NNN are the two
halves of ONE sample, not two samples.

    runmilo.py DA_fwd.in --backward           # one reversed run per finished member

Each trajectory gets its own directory:

    results/<base>_001/<base>_001.{out,xyz,png}
    results/<base>_002/...
    results.failed/<base>_003.XXXXXX/   on failure, with the Gaussian .com/.log tarball

A single trajectory is member 001 of the same ensemble, so the run used to test
a system and the run used to produce it are the same code path.

CPUs and memory come from `processors`/`memory` in the $job section, so the
Slurm allocation cannot drift from what Milo writes into each Gaussian .com.
--cpus/--mem override both together, rewriting only the scratch copy of the
input, which is what lets one .in serve two resource profiles:

    runmilo.py DA_fwd.in --cpus 16                             # quick test
    runmilo.py DA_fwd.in --traj 100 --cpus 8 --array-limit 4   # production

Wide is for latency (one trajectory, answered quickly); narrow is for
throughput (many trajectories, more of them at once).

Measured on the 16-atom Diels-Alder at wb97xd/6-31G*, 50 steps: 2c 338 s,
4c 200 s, 8c 172 s, 16c 148 s, 24c 191 s -- i.e. 24 cores is past the knee and
slower than 16. That knee moves right with basis-function count, not atom
count, so a larger system will use 8 cores better than this one does. 8 is the
standing production choice; re-measure only if a system behaves oddly.

Portability: --site selects a cluster preset (g16 setup, node-local scratch,
account/partition). MILO_HOME and MILO_SCRATCH override the paths at submit
time; --account/--partition/--constraint override the preset.

    runmilo.py DA_fwd.in --site expanse --traj 100 --cpus 8 --array-limit 12

Run it on a cluster from this directory, without logging in (see remotejob.py):

    runmilo.py DA_fwd.in --traj 20 --hoffman2     # rsync up, qsub there
    rjob fetch                                    # results back here, remote copy deleted

Note that --mem is only advisory on the workstation (TaskPlugin=task/none) but
is enforced by cgroups on Expanse, where under-declaring it kills the member.
"""
from __future__ import annotations

import argparse
import hashlib
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

LOCAL = Path(__file__).resolve().parent
PLOT = LOCAL / 'plot_traj.py'

# The plot needs ase + matplotlib. A Slurm job's default python3 is whichever
# conda env sits first on PATH (currently ambertools26, which has neither), so
# the interpreter is resolved here and baked into the script as an absolute path.
PLOT_PY_CANDIDATES = (
    sys.executable,
    str(Path.home() / 'miniconda3/envs/pygsm/bin/python'),
    str(Path.home() / 'miniconda3/envs/py311/bin/python'),
)


# Per-cluster differences, verified 2026-09-12. Only three things actually vary:
# how g16 gets onto PATH, where node-local scratch lives, and whether Slurm
# demands an account/partition. Expanse has no bsd/g16.profile -- the module
# sets PATH/GAUSS_EXEDIR/G16_BASIS itself -- so do not source one there.
SITES = {
    'local': {
        'g16_init': 'source /etc/g16setup',
        'scratch_root': '${SLURM_TMPDIR:-/tmp}',
        'account': None,
        'partition': None,
        'scheduler': 'slurm',
        'milo_home': '$HOME/Programs/milo',
        'python': 'python3',
    },
    'hoffman2': {
        # Modules first; `module load gaussian` is G16 C.02 avx here.
        'g16_init': ('. /u/local/Modules/default/init/modules.sh\n'
                     'module load gaussian\n'
                     '# Not the login python3: that is a personal conda env on\n'
                     '# this account and will not exist on someone else\'s.\n'
                     'module load python/3.9.6'),
        # $TMPDIR is node-local and UGE removes it; $SCRATCH is the fallback and
        # is initial-sharded (/u/scratch/a/<user>), not /u/scratch/<user>.
        'scratch_root': '${TMPDIR:-$SCRATCH}',
        'account': None,
        'partition': None,
        'scheduler': 'uge',
        # Where install_milo.sh puts it by default. If yours lives anywhere
        # else (a group directory, a project allocation), export MILO_HOME --
        # install_milo.sh --add-path writes that line for you. The script
        # fails loudly rather than guessing if neither path exists.
        'milo_home': '$HOME/Programs/milo-1.0.3',
        'python': 'python3',   # from the module above, not from PATH
    },
    'expanse': {
        # module is not a function in a non-login batch shell; initialise lmod
        # first if it is missing.
        'g16_init': ('command -v module >/dev/null 2>&1 || '
                     'source /usr/share/lmod/lmod/init/bash\n'
                     'module load cpu/0.15.4 gaussian/16.C.01'),
        # Node-local NVMe. The scheduler owns this root and cleans it up; we
        # only ever create and delete our own child inside it. :-$$ keeps the
        # script runnable outside Slurm, where SLURM_JOB_ID is unset.
        'scratch_root': '/scratch/$USER/job_${SLURM_JOB_ID:-$$}',
        # Your allocation, not a shared one: export MILO_ACCOUNT, or pass
        # --account. Unset means Slurm falls back to your default account.
        'account': os.environ.get('MILO_ACCOUNT'),
        'partition': 'shared',
        'scheduler': 'slurm',
        'milo_home': '$HOME/Programs/milo',
        'python': 'python3',
    },
}


# Slurm and UGE differ in about ten places; the body of the script -- skip
# guard, seed guard, staging, traps, META/FOOTER -- is identical and is not
# forked. Adding a cluster means adding a SITES entry, not a second generator.
SCHEDULERS = {
    'slurm': {
        'shebang': '#!/bin/bash',
        'submit': 'sbatch',
        'task_id': '${SLURM_ARRAY_TASK_ID:-1}',
        'job_id': '${SLURM_JOB_ID:-$$}',
        'job_report': '${SLURM_JOB_ID:-(no scheduler)}',
        'array_report': '${SLURM_ARRAY_JOB_ID:-(none)} task ${SLURM_ARRAY_TASK_ID:-1}',
        'submit_dir': '${SLURM_SUBMIT_DIR:-$PWD}',
        # Slurm sends TERM on scancel; UGE sends USR1 at s_rt, ~5 min before the
        # hard limit, which is the only warning a walltime kill ever gives.
        'signals': 'INT TERM',
    },
    'uge': {
        'shebang': '#!/bin/bash -l',
        'submit': 'qsub',
        'task_id': '${SGE_TASK_ID:-1}',
        'job_id': '${JOB_ID:-$$}',
        'job_report': '${JOB_ID:-(no scheduler)}',
        'array_report': '${JOB_ID:-(none)} task ${SGE_TASK_ID:-1}',
        'submit_dir': '${SGE_O_WORKDIR:-$PWD}',
        'signals': 'INT TERM USR1',
    },
}

# qsub is not on PATH in a non-interactive shell on Hoffman2 (runorca.py hits
# the same thing), so the known locations are tried before giving up.
QSUB_CANDIDATES = (
    '/u/systems/UGE8.6.4/bin/lx-amd64/qsub',
    '/u/local/bin/qsub',
    '/usr/bin/qsub',
)


def submit_command(scheduler: str) -> str | None:
    name = SCHEDULERS[scheduler]['submit']
    found = shutil.which(name)
    if found:
        return found
    if name == 'qsub':
        return next((c for c in QSUB_CANDIDATES if Path(c).is_file()), None)
    return None


def hms_to_seconds(walltime: str) -> int:
    h, m, sec = (int(x) for x in walltime.split(':'))
    return h * 3600 + m * 60 + sec


def uge_directives(base: str, jobname: str, cpus: str, mem: str, walltime: str,
                   array: str, limit: int | None, constraint: str | None) -> str:
    """The Gsub.py / runorca.py house idiom: one combined -l line, times in
    seconds, h_data per slot and h_vmem per slot x slots, highp past 24 h so the
    job lands on Houk-owned nodes."""
    total_mb = (int(mem) + 4) * 1024
    per_slot = -(-total_mb // int(cpus))          # ceil: h_data is per slot
    h_rt = hms_to_seconds(walltime)
    s_rt = max(60, h_rt - 300)                    # USR1 arrives here
    limits = [f'h_data={per_slot}M', f'h_vmem={per_slot * int(cpus)}M',
              f'h_rt={h_rt}', f's_rt={s_rt}']
    if h_rt > 24 * 3600:
        limits.append('highp')
    limits.append(f'arch={constraint or "intel*"}')
    lines = ['#$ -cwd', f'#$ -N {jobname}',
             '#$ -o joblogs/joblog.$JOB_NAME.$JOB_ID.$TASK_ID',
             '#$ -j y', '#$ -notify', f'#$ -t {array}']
    if limit:
        lines.append(f'#$ -tc {limit}')
    lines += [f'#$ -pe shared* {cpus}', '#$ -l ' + ','.join(limits)]
    return '\n'.join(lines)


def detect_site() -> str:
    """Which cluster is this? Slurm already knows; asking it beats matching
    hostnames, and it is right on login and compute nodes alike."""
    try:
        out = subprocess.run(['scontrol', 'show', 'config'],
                             capture_output=True, text=True, timeout=10)
        m = re.search(r'^ClusterName\s*=\s*(\S+)', out.stdout, re.M)
        name = m.group(1).casefold() if m else ''
        if name in SITES:
            return name
    except (OSError, subprocess.SubprocessError):
        pass   # no Slurm here at all, which is the normal case on Hoffman2
    # UGE announces itself through SGE_ROOT, set for login and batch shells
    # alike; qsub off PATH is expected in a non-interactive shell.
    if os.environ.get('SGE_ROOT') or submit_command('uge'):
        return 'hoffman2'
    return 'local'


def plot_interpreter() -> str | None:
    for exe in PLOT_PY_CANDIDATES:
        if not Path(exe).is_file():
            continue
        probe = subprocess.run([exe, '-c', 'import ase, matplotlib'],
                               capture_output=True)
        if probe.returncode == 0:
            return exe
    return None


def parse_args():
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument('inputs', nargs='+', help='Milo input files (.in)')
    p.add_argument('--site', choices=sorted(SITES) + ['auto'], default='auto',
                   help='cluster preset: g16 setup, scratch path, and any '
                        'required account/partition. Default auto, read from '
                        "Slurm's own ClusterName.")
    p.add_argument('--hoffman2', dest='remote', action='store_const',
                   const='hoffman2',
                   help='build for Hoffman2 AND run it there: rsync this '
                        'directory up, qsub, `rjob fetch` brings the results '
                        'back into it.')
    p.add_argument('--expanse', dest='remote', action='store_const',
                   const='expanse', help='same, on Expanse.')
    p.add_argument('--wait', action='store_true',
                   help='with --hoffman2/--expanse: block until the job '
                        'finishes, then fetch.')
    p.add_argument('-n', '--traj', type=int, default=1,
                   help='number of trajectories in the ensemble (default: 1)')
    p.add_argument('-p', '--cpus', type=int, default=None,
                   help='override `processors` from the $job section. Rewrites '
                        'the scratch copy of the input only, so one .in serves '
                        'both a fat quick test and a narrow parallel ensemble.')
    p.add_argument('-m', '--mem', type=int, default=None,
                   help='override `memory` (GB) from the $job section')
    p.add_argument('--array-limit', type=int, default=None,
                   help='max array members running at once (Slurm %%K). Set it '
                        'whenever --cpus is small enough that many members fit '
                        'on a node; locally it is the only real throttle, since '
                        '--mem is advisory there (TaskPlugin=task/none).')
    p.add_argument('--backward', action='store_true',
                   help='run the reverse half of each finished forward member: '
                        'flip the phase and replay that member\'s seed. The '
                        'array is sized from what is actually in results/, so '
                        '--traj does not apply.')
    p.add_argument('--pairs', nargs='+', default=None,
                   help='1-based atom pairs to plot, e.g. 1-5 4-6 '
                        '(default: the pair named by `phase`)')
    p.add_argument('-t', '--time', default='48:00:00',
                   help='walltime: 24 or 24h (hours), 90m (minutes), or '
                        'HH:MM:SS (default: 48:00:00)')
    p.add_argument('--account', default=None, help='Slurm account (-A)')
    p.add_argument('--partition', default=None, help='Slurm partition (-p)')
    p.add_argument('--constraint', default=None, help='Slurm constraint (-C)')
    p.add_argument('--dry-run', action='store_true',
                   help='write the script and print it, but do not submit')
    p.add_argument('--no-submit', action='store_true',
                   help='write the script but do not submit')
    p.add_argument('--force', action='store_true',
                   help='overwrite an existing <base>_milo.sh (does NOT touch '
                        'finished results)')
    p.add_argument('--rerun', action='store_true',
                   help='also re-run ensemble members that already have '
                        'results, replacing them. Implies --force. This is the '
                        'destructive one: regenerating a script and discarding '
                        'finished trajectories are separated on purpose.')
    args = p.parse_args()
    args.time = walltime(args.time, p)
    # --hoffman2/--expanse mean "build for it AND run it there" -- one flag.
    if args.remote:
        args.site = args.remote
    elif args.wait:
        p.error('--wait only means anything with --hoffman2/--expanse.')
    if args.site == 'auto':
        args.site = detect_site()
    if args.rerun:
        args.force = True
    if args.backward and args.traj != 1:
        p.error('--backward sizes its array from the finished forward members '
                'in results/, so it cannot take --traj.')
    return args


def array_spec(members: list[int]) -> str:
    """The array for these member indices: a range if they are contiguous, an
    explicit list if a forward member failed and left a hole. The throttle is
    not folded in -- Slurm spells it %N inside the spec, UGE spells it -tc N."""
    contiguous = members == list(range(members[0], members[-1] + 1))
    return (f'{members[0]}-{members[-1]}' if contiguous
            else ','.join(str(m) for m in members))


def finished_members(base: str) -> list[int]:
    """Indices of ensemble members that published a complete trajectory."""
    done = []
    for d in Path('results').glob(f'{base}_[0-9][0-9][0-9]*'):
        # Any index width, not just three digits: %03d does not truncate, so a
        # 1000-member ensemble really does produce <base>_1000. The fullmatch
        # also keeps <base>_001_rev out of the forward member list.
        m = re.fullmatch(rf'{re.escape(base)}_(\d+)', d.name)
        out, xyz = d / f'{d.name}.out', d / f'{d.name}.xyz'
        if m and out.is_file() and out.stat().st_size and xyz.is_file() \
                and xyz.stat().st_size:
            done.append(int(m.group(1)))
    return sorted(done)


# setup_backward.py flips exactly these two, case-sensitively (it detects with
# casefold but replaces with str.replace), and leaves anything else untouched
# with only a printed warning. `phase random` has no opposite at all.
OPPOSITE_PHASE = {'bring_together': 'push_apart', 'push_apart': 'bring_together'}


def phase_direction(text: str) -> str | None:
    m = re.search(r'^\s*phase\s+(\S+)', text, re.M)
    return m.group(1) if m else None


def out_seed(out_file: Path) -> str | None:
    """The seed Milo recorded in a finished .out."""
    lines = out_file.read_text(errors='replace').splitlines()
    for i, line in enumerate(lines[:-1]):
        if line.startswith('### Random Seed'):
            return lines[i + 1].strip()
    return None


def milo_home(site: str) -> Path:
    """Where Milo lives on this host. Not every cluster puts it in the same
    place, and MILO_HOME overrides the preset, exactly as the generated
    script does."""
    return Path(os.environ.get('MILO_HOME')
                or os.path.expandvars(SITES[site]['milo_home']))


def write_backward_inputs(base: str, members: list[int], cpus: str, mem: str,
                          walltime: str, direction: str, site: str) -> Path:
    """Generate one reversed input per finished member, in backward/.

    Milo ships the reversal (tools/setup_backward.py): it flips
    bring_together/push_apart and stamps the forward run's seed into the new
    $job section. It globs *.out in the directory it runs from and writes
    beside them, so it is run once per member directory -- that is what the
    per-trajectory layout costs here. Regenerated every time: the .out is the
    only source of truth for a reversed input.
    """
    tool = milo_home(site) / 'milo_1_0_3/tools/setup_backward.py'
    if not tool.is_file():
        sys.exit(f'ERROR: {tool} not found; cannot build reversed inputs.')
    out_dir = Path('backward')
    out_dir.mkdir(exist_ok=True)
    for idx in members:
        member = f'{base}_{idx:03d}'
        run = subprocess.run(
            # setup_backward.py:113 deliberately writes `memory - 1` into the
            # .in (its own scripts request one GB more than Gaussian gets), so
            # it is handed mem + 1 to land on mem. The job script re-writes both
            # values in scratch anyway; this only keeps backward/*.in honest to
            # a human reading it.
            [sys.executable, str(tool), '-t', walltime, '-m', str(int(mem) + 1),
             '-p', cpus, '--no_script'],
            cwd=Path('results') / member, capture_output=True, text=True)
        produced = Path('results') / member / f'{member}_rev.in'
        if run.returncode != 0 or not produced.is_file():
            sys.exit(f'ERROR: setup_backward.py failed for {member}: '
                     f'{(run.stderr or run.stdout).strip()}')
        # setup_backward.py reports an unreversed phase as a printed warning and
        # still exits 0, and it writes `random_seed None` if the .out was
        # truncated before its seed. Either one produces a file that looks like
        # a backward input and is not one, so read back what was written.
        made = produced.read_text()
        got = phase_direction(made)
        if got != OPPOSITE_PHASE[direction]:
            sys.exit(f'ERROR: reversed input for {member} has `phase {got}`, '
                     f'expected `{OPPOSITE_PHASE[direction]}`. '
                     f'{run.stdout.strip()}')
        seed = job_value(made, 'random_seed')
        want = out_seed(Path('results') / member / f'{member}.out')
        if seed != want or not (seed or '').isdigit():
            sys.exit(f'ERROR: reversed input for {member} carries '
                     f'`random_seed {seed}`, but that member ran with {want}. '
                     'The reverse would not replay the forward trajectory.')
        produced.replace(out_dir / produced.name)
    return out_dir


def walltime(value: str, parser) -> str:
    """`24`, `24h`, `90m` or `HH:MM:SS` -> what Slurm wants."""
    if re.fullmatch(r'\d+:\d{2}:\d{2}', value):
        return value
    m = re.fullmatch(r'(\d+)\s*([hHmM]?)', value)
    if not m:
        parser.error(f'--time {value!r}: use 24, 24h, 90m, or HH:MM:SS')
    n, unit = int(m.group(1)), m.group(2).casefold()
    hours, minutes = (n // 60, n % 60) if unit == 'm' else (n, 0)
    return f'{hours:02d}:{minutes:02d}:00'


def input_fingerprint(text: str) -> str:
    """The parts of an input that define the trajectory.

    `processors`/`memory` are rewritten per submission by --cpus/--mem, and
    comments are stripped by Milo before parsing, so neither makes two
    ensembles different. Everything else does.
    """
    keep = []
    for line in text.splitlines():
        line = re.sub(r'#.*', '', line).strip()
        if line and not re.match(r'(processors|memory)\s', line):
            keep.append(line)
    return hashlib.sha256('\n'.join(keep).encode()).hexdigest()[:12]


def embedded_input(out: Path) -> str | None:
    """The input a finished member actually ran, as Milo echoed it back."""
    m = re.search(r'### Input File[^\n]*\n(.*?)\n### ',
                  out.read_text(errors='replace'), re.S)
    return m.group(1) if m else None


def job_value(text: str, key: str) -> str | None:
    m = re.search(rf'^\s*{key}\s+(\S+)', text, re.M)
    return m.group(1) if m else None


def phase_pair(text: str) -> list[str]:
    """Bonds to follow: the `# pairs` line prepmilo stamps into $job if it is
    there, else the single pair named by `phase bring_together n m`.

    prepmilo knows every pair that moves along the imaginary mode; `phase` can
    only name one of them. Reading the stamp is what keeps --pairs off the
    command line for the ordinary two-bond case."""
    m = re.search(r'^\s*#\s*pairs\s+([\d\s-]+)$', text, re.M)
    if m:
        return m.group(1).split()
    m = re.search(r'^\s*phase\s+\w+\s+(\d+)\s+(\d+)', text, re.M)
    return [f'{m.group(1)}-{m.group(2)}'] if m else []


def build_script(base: str, cpus: str, mem: str, pairs: list[str], walltime: str,
                 plot_py: str | None, traj: int, array: str, limit: int | None,
                 account: str | None, partition: str | None,
                 constraint: str | None, site: str, rerun: bool,
                 backward: bool) -> str:
    cfg = SITES[site]
    g16_init = cfg['g16_init']
    scratch_root = cfg['scratch_root']
    account = account or cfg['account']
    partition = partition or cfg['partition']
    sched = SCHEDULERS[cfg['scheduler']]
    python = cfg['python'] or sys.executable
    jobname = f'{base}{"_rev" if backward else ""}.milo'
    if cfg['scheduler'] == 'uge':
        span = array
        if ',' in array:
            parts = [int(x) for x in array.split(',')]
            span = f'{min(parts)}-{max(parts)}'
        directives = uge_directives(base, jobname, cpus, mem, walltime,
                                    span, limit, constraint)
    else:
        directives = '\n'.join(
            [f'#SBATCH --job-name={jobname}',
             '#SBATCH --output=joblogs/joblog.%x.%A_%a',
             f'#SBATCH --array={array}' + (f'%{limit}' if limit else ''),
             f'#SBATCH --nodes=1 --ntasks=1 --cpus-per-task={cpus}',
             f'#SBATCH --mem={int(mem) + 4}G   # {mem} GB for Gaussian (%mem)'
             ' + headroom for g16 and Milo',
             f'#SBATCH --time={walltime}']
            + [f'#SBATCH {flag} {value}'
               for flag, value in (('-A', account), ('-p', partition),
                                   ('-C', constraint)) if value])
    # UGE's -t takes one range, not a comma list, so a backward ensemble with a
    # hole submits the whole range and the members that are not part of it step
    # aside. Slurm says this in the array spec itself.
    roster = ''
    if cfg['scheduler'] == 'uge' and ',' in array:
        members = array.replace(',', ' ')
        roster = (f'MEMBERS="{members}"\n'
                  'case " $MEMBERS " in *" $TASK_ID "*) ;; *)\n'
                  '  echo "SKIP: member $TASK_ID is not part of this ensemble."\n'
                  '  exit 0;; esac\n')
    plot_cmd = ''
    if pairs and plot_py:
        plot_cmd = (f'    "{plot_py}" "{PLOT}" "$RESULTS/$BASE.xyz" '
                    f'--pairs {" ".join(pairs)} --energy "$RESULTS/$BASE.out" '
                    f'-o "$RESULTS/$BASE.png" || '
                    'echo "WARNING: plotting failed" >&2')
    identity = f'{base}_${{TASK}}_rev' if backward else f'{base}_$TASK'
    # Backward members each get their own input: it carries that forward
    # member's seed, which is the whole point -- same initial conditions, mode 0
    # flipped. Forward members all share one input and seed themselves at run
    # time. See write_backward_inputs().
    input_expr = 'backward/$BASE.in' if backward else f'{base}.in'
    # A reverse result only belongs to the forward member that is on disk now.
    # Re-running a forward member gives it a new seed, so the reversed input is
    # regenerated and the old reverse result becomes a different sample. Skipping
    # it would publish a mismatched pair, which is exactly the error a footer
    # says nothing about -- so refuse instead.
    stale_guard = '''if [[ $FORCE -eq 0 && -s "$RESULTS/$BASE.out" ]]; then
  want=$(awk '$1=="random_seed"{print $2}' "$INPUT" | head -1)
  got=$(grep -A1 '### Random Seed' "$RESULTS/$BASE.out" | tail -1 | tr -d '[:space:]')
  if [[ -n "$want" && -n "$got" && "$want" != "$got" ]]; then
    echo "ERROR: $RESULTS/$BASE.out replays seed $got, but $INPUT now carries" \\
         "$want -- the forward member was re-run, so the result on disk is the" \\
         "partner of a trajectory that no longer exists. Re-run runmilo.py" \\
         "--backward --rerun to replace it." >&2
    exit 1
  fi
fi

''' if backward else ''
    seed_note = (
        '# Milo takes its job name from the stdout redirect target\n'
        '# (input_parser.py:266), so `> $BASE.out` also makes it write $BASE.xyz.\n'
        + ('# This member replays forward member $TASK\'s seed with the phase\n'
           '# reversed, so it is the other half of that trajectory, not a new sample.'
           if backward else
           '# Nothing else distinguishes the members: each draws its own seed from\n'
           '# os.urandom and records it in the .out.'))
    return f'''{sched["shebang"]}
# Generated by runmilo.py. {traj} {"backward " if backward else ""}Milo {"trajectory" if traj == 1 else "trajectories"}: {sched["submit"]} {base}{"_rev" if backward else ""}_milo.sh
{directives}

set -uo pipefail

# Environment-specific (--site {site}). MILO_HOME relocates Milo itself.
MILO_HOME="${{MILO_HOME:-{cfg["milo_home"]}}}"

CPUS={cpus}                                        # Gaussian %nprocshared
MEM={mem}                                          # Gaussian %mem, GB
# UGE sets SGE_TASK_ID to the string "undefined" outside an array job, so the
# index is validated rather than trusted.
TASK_ID="{sched['task_id']}"
[[ "$TASK_ID" =~ ^[0-9]+$ ]] || TASK_ID=1
{roster}TASK=$(printf '%03d' "$TASK_ID")             # member index
BASE="{identity}"                                  # output identity
INPUT="{input_expr}"
FORCE={int(rerun)}

SUBMIT_DIR="{sched['submit_dir']}"
cd "$SUBMIT_DIR" || exit 1
mkdir -p joblogs
[[ -f "$INPUT" ]] || {{ echo "ERROR: $SUBMIT_DIR/$INPUT not found" >&2; exit 1; }}

{seed_note}
SCRATCH_ROOT="${{MILO_SCRATCH:-{scratch_root}}}"
# Always a job-unique child: the job id differs per array task, so members
# never share a directory even if SCRATCH_ROOT is a fixed path. Only the child
# is ever deleted -- the root belongs to the scheduler on Expanse and Hoffman2.
SCRATCH="$SCRATCH_ROOT/milo_{sched['job_id']}_$BASE"
# One directory per trajectory: results/<base>_NNN/ holds that member's
# .out/.xyz/.png. At 100 members a flat results/ is 300 files.
RESULTS="$SUBMIT_DIR/results/$BASE"
FAILED_ROOT="$SUBMIT_DIR/results.failed"
FAILED=""   # set by mktemp on the failure path, so retries can never collide

{stale_guard}# Already finished? Re-running would overwrite a good trajectory, and on requeue
# that happens silently. --rerun is the only way past this.
if [[ $FORCE -eq 0 && -s "$RESULTS/$BASE.out" && -s "$RESULTS/$BASE.xyz" ]]; then
  echo "SKIP: $BASE already has results; re-run runmilo.py with --rerun to replace it."
  exit 0
fi

# Trap order: INT/TERM kills the child and exits 130; EXIT then always runs and
# writes the footer, even if staging fails. Do not reorder. Installed before the
# g16/PYTHONPATH setup so an environment failure still produces a footer.
_kill_child() {{ [[ -n "${{pid:-}}" ]] && kill "$pid" 2>/dev/null; exit 130; }}
_on_exit() {{
  rc=$?
  # Stage through temp names and rename, so a half-copied member never appears
  # complete in results/ and never gets counted by downstream analysis.
  if [[ $rc -eq 0 ]] && mkdir -p "$RESULTS" \\
     && cp -p "$SCRATCH/$BASE.out" "$RESULTS/.$BASE.out.part" \\
     && cp -p "$SCRATCH/$BASE.xyz" "$RESULTS/.$BASE.xyz.part" \\
     && mv -f "$RESULTS/.$BASE.out.part" "$RESULTS/$BASE.out" \\
     && mv -f "$RESULTS/.$BASE.xyz.part" "$RESULTS/$BASE.xyz"; then
{plot_cmd}
    rm -rf "$SCRATCH"
  else
    rm -f "$RESULTS/.$BASE.out.part" "$RESULTS/.$BASE.xyz.part"
    # Only a failed run needs the per-step Gaussian .com/.log files; on success
    # they are ~1 MB of noise per trajectory. Keep them only when debugging.
    [[ $rc -eq 0 ]] && {{ rc=1; echo "ERROR: copy-back to $RESULTS failed" >&2; }}
    mkdir -p "$FAILED_ROOT"
    FAILED=$(mktemp -d "$FAILED_ROOT/$BASE.XXXXXX") || FAILED=""
    if [[ -n "$FAILED" ]]; then
      cp -p "$SCRATCH"/*.out "$SCRATCH"/*.xyz "$FAILED"/ 2>/dev/null
      tar -C "$SCRATCH" -czf "$FAILED/${{BASE}}_gaussian_com_log.tar.gz" . 2>/dev/null \
        || echo "WARNING: could not archive Gaussian .com/.log files" >&2
    else
      echo "WARNING: could not create a failure directory under $FAILED_ROOT" >&2
    fi
  fi
  echo "================ MILO RUN FOOTER ================"
  echo "ended: $(date -Is)"
  echo "exit_code: $rc"
  [[ $rc -ne 0 ]] && echo "scratch_preserved: $SCRATCH"
  [[ $rc -ne 0 && -n "$FAILED" ]] && echo "failed_artifacts: $FAILED"
  exit $rc
}}
trap _kill_child {sched['signals']}
trap _on_exit EXIT

# g16.profile references LD_LIBRARY64_PATH unguarded and lmod touches unset
# vars, so both need `set -u` off.
set +u
{g16_init}
set -u
[[ -f "$MILO_HOME/milo_1_0_3/__main__.py" ]] || {{
  echo "ERROR: no Milo at $MILO_HOME. Set MILO_HOME, or install it with" \\
       "install_milo.sh." >&2; exit 1; }}
export PYTHONPATH="$MILO_HOME${{PYTHONPATH:+:$PYTHONPATH}}"

echo "================ MILO RUN META ================"
echo "started:     $(date -Is)"
echo "host:        $(hostname)"
echo "job:         {sched['job_report']}"
echo "array:       {sched['array_report']} of {traj}"
echo "member:      $BASE"
echo "submit dir:  $SUBMIT_DIR"
echo "scratch:     $SCRATCH"
echo "binary:      $(which g16) | milo 1.0.3 @ $MILO_HOME"
echo "python:      $("{python}" -V)"
echo "milo_hash:   $(find "$MILO_HOME/milo_1_0_3" -name '*.py' | sort | xargs sha256sum | sha256sum | cut -c1-12)"
echo "input:       $INPUT ($(sha256sum "$INPUT" | cut -c1-12))"
echo "resources:   $CPUS cpus, $MEM GB to Gaussian"
echo "================ MILO STDOUT/STDERR ================"

mkdir -p "$SCRATCH"
cp -p "$INPUT" "$SCRATCH"/
# $INPUT may carry a directory (backward/), but in scratch it is flat.
IN="$(basename "$INPUT")"
# Milo bakes processors/memory into every per-step Gaussian .com, so an override
# has to rewrite the input, not just the Slurm request. Scratch copy only -- the
# .in in the submit dir is never modified.
sed -i -E "s|^([[:space:]]*processors[[:space:]]+).*|\\1$CPUS|; \\
           s|^([[:space:]]*memory[[:space:]]+).*|\\1$MEM|" "$SCRATCH/$IN" || {{
  echo "ERROR: could not rewrite resources in $SCRATCH/$IN" >&2; exit 1; }}
# Read the values back. A silent rewrite failure would leave Milo asking Gaussian
# for the original core count inside a smaller cgroup -- oversubscription on a
# cgroup cluster, and a Slurm allocation that no longer matches %nprocshared.
got_c=$(awk '$1=="processors"{{print $2}}' "$SCRATCH/$IN" | head -1)
got_m=$(awk '$1=="memory"{{print $2}}' "$SCRATCH/$IN" | head -1)
if [[ "$got_c" != "$CPUS" || "$got_m" != "$MEM" ]]; then
  echo "ERROR: resource rewrite did not take (processors=$got_c memory=$got_m," \
       "wanted $CPUS/$MEM). Refusing to run with a mismatched allocation." >&2
  exit 1
fi
cd "$SCRATCH" || exit 1
export GAUSS_SCRDIR="$SCRATCH"
"{python}" -m milo_1_0_3 < "$IN" > "$BASE.out" &
pid=$!
wait $pid
'''


def main():
    args = parse_args()
    if args.traj < 1:
        sys.exit(f'ERROR: --traj must be at least 1, got {args.traj}')
    # plot_interpreter() returns a path on THIS machine, and plot_traj.py
    # lives next to this script -- neither exists on the cluster. Plot after
    # `rjob fetch`, when the trajectories are back here.
    plot_py = None if args.remote else plot_interpreter()
    if plot_py is None and not args.remote:
        print('NOTE: no interpreter with ase + matplotlib found; '
              'trajectories will run but will not be plotted.', file=sys.stderr)
    # Two passes: validate and build everything first, submit only after every
    # input has passed. A bad third input must not leave two jobs already live.
    jobs = []
    for spec in args.inputs:
        path = Path(spec if spec.endswith('.in') else f'{spec}.in')
        if not path.is_file():
            sys.exit(f'ERROR: {path} not found')
        text = path.read_text()
        base = path.stem
        if '.' in base:
            sys.exit(f"ERROR: {path} has a dot in its name. Milo derives its job "
                     "name from the output filename and truncates at the first "
                     "dot (input_parser.py:268), so the members would collide.")
        cpus = job_value(text, 'processors')
        mem = job_value(text, 'memory')
        if not (cpus and mem):
            sys.exit(f"ERROR: {path} has no 'processors'/'memory' in its $job section")
        if args.cpus:
            cpus = str(args.cpus)
        if args.mem:
            mem = str(args.mem)
        for name, value in (('processors', cpus), ('memory', mem)):
            if not value.isdigit() or int(value) < 1:
                sys.exit(f'ERROR: {path} has a non-positive {name} ({value!r})')

        script = Path(f'{base}_rev_milo.sh' if args.backward
                      else f'{base}_milo.sh')
        if script.exists() and not (args.force or args.dry_run):
            sys.exit(f'ERROR: refusing to overwrite {script}. Re-run with --force.')

        members = list(range(1, args.traj + 1))
        if args.backward:
            members = finished_members(base)
            if not members:
                sys.exit(f'ERROR: no finished members of {base} in results/. '
                         'Run the forward ensemble first.')
            direction = phase_direction(text)
            if direction not in OPPOSITE_PHASE:
                sys.exit(f'ERROR: {path} has `phase {direction}`, which has no '
                         'reverse. --backward needs exactly `bring_together` or '
                         '`push_apart`, lower case: Milo reads phase '
                         'case-insensitively but setup_backward.py flips it with '
                         'a case-sensitive replace, so `BRING_TOGETHER` would '
                         'come back unreversed.')
            if args.dry_run:
                print(f'NOTE: --dry-run; not writing backward/ inputs for the '
                      f'{len(members)} finished member(s) of {base}.',
                      file=sys.stderr)
            else:
                # The reversal runs locally on the fetched results, so it
                # needs the local Milo even when the job goes to a cluster.
                write_backward_inputs(base, members, cpus, mem, args.time,
                                      direction,
                                      'local' if args.remote else args.site)
                print(f'NOTE: {len(members)} reversed input(s) written to '
                      f'backward/ from finished members of {base}.',
                      file=sys.stderr)

        # An ensemble is only an ensemble if the members differ. Milo reseeds
        # deterministically from an explicit integer (input_parser.py:498-502),
        # so N members of an explicitly seeded input are N identical
        # trajectories that still look like a valid ensemble. Absent means
        # generate, which is fine.
        seed = job_value(text, 'random_seed')
        if (args.traj > 1 and not args.backward
                and seed is not None and seed.casefold() != 'generate'):
            sys.exit(f"ERROR: {path} has an explicit `random_seed {seed}`, so all "
                     f"{args.traj} members would run the identical trajectory. "
                     "Set `random_seed generate` for an ensemble, or use "
                     "--traj 1 to reproduce this one seed deliberately.")

        if (args.traj == 1 and not args.backward
                and seed is not None and seed.casefold() != 'generate'):
            print(f'NOTE: {path} pins `random_seed {seed}`, so this reproduces '
                  'one specific trajectory rather than sampling a new one.',
                  file=sys.stderr)

        limit = args.array_limit
        if limit is None and args.site == 'local' and args.traj > 1:
            # --mem is advisory here (TaskPlugin=task/none), so nothing stops
            # 100 members from starting at once and thrashing the box. Cap them
            # at the core count. On a cgroup cluster the scheduler does this.
            limit = max(1, (os.cpu_count() or 8) // int(cpus))
            print(f'NOTE: --array-limit {limit} ({os.cpu_count()} cores / '
                  f'{cpus} per member). Pass --array-limit to override.',
                  file=sys.stderr)

        pairs = args.pairs or phase_pair(text)
        if not pairs:
            print(f'NOTE: {path} has no `phase` pair and no --pairs; '
                  'skipping the plot for this one.', file=sys.stderr)

        stem = f'{base}_[0-9][0-9][0-9]' + ('_rev' if args.backward else '')
        done = sorted(Path('results').glob(f'{stem}/{stem}.out')) \
            if Path('results').is_dir() else []
        if done:
            if args.rerun:
                print(f'WARNING: --rerun will replace {len(done)} finished '
                      f'member(s) of {base}.', file=sys.stderr)
            else:
                # --force grows an ensemble: the finished members stay and the
                # rest are filled in. That is only sound if they ran the same
                # input. Editing the .in and re-submitting would otherwise mix
                # two specifications into one ensemble, and every member would
                # look equally valid afterwards.
                # Backward members ran their own reversed inputs, not this
                # one; their pairing is guarded by the seed check instead.
                want = input_fingerprint(text)
                stale = [] if args.backward else [
                    f.parent.name for f in done
                    if (embedded_input(f) or '') and
                    input_fingerprint(embedded_input(f)) != want]
                if stale:
                    shown = ', '.join(stale[:3])
                    more = f' (+{len(stale) - 3} more)' if len(stale) > 3 else ''
                    sys.exit(
                        f'ERROR: {len(stale)} finished member(s) of {base} ran a '
                        f'different input than {path}: {shown}{more}. Keeping '
                        'them would mix two specifications into one ensemble. '
                        'Use --rerun to replace them, or submit under a new '
                        'name to keep both.')
                print(f'NOTE: {len(done)} member(s) of {base} already have '
                      'results; those array tasks will skip. Use --rerun to '
                      'replace them.', file=sys.stderr)

        body = build_script(base=base, cpus=cpus, mem=mem, pairs=pairs,
                            walltime=args.time, plot_py=plot_py,
                            traj=len(members),
                            array=array_spec(members), limit=limit,
                            account=args.account, partition=args.partition,
                            constraint=args.constraint, site=args.site,
                            rerun=args.rerun, backward=args.backward)
        jobs.append((base, cpus, mem, pairs, script, body, len(members)))

    if args.dry_run:
        for *_, body, _count in jobs:
            print(body)
        return

    # Slurm opens the --output path before the job body runs, so joblogs/ has to
    # exist at submit time, not be created inside the script.
    Path('joblogs').mkdir(exist_ok=True)

    for base, cpus, mem, pairs, script, body, count in jobs:
        script.write_text(body)
        script.chmod(0o755)
        if args.no_submit:
            print(f'wrote {script} (not submitted)')
            continue
        if args.remote:
            import remotejob      # ~/bin/Modules (PYTHONPATH); also the `rjob` CLI
            jobid = remotejob.submit(args.remote, script)
        else:
            submit = submit_command(SITES[args.site]['scheduler'])
            if submit is None:
                sys.exit(f'ERROR: no {SCHEDULERS[SITES[args.site]["scheduler"]]["submit"]}'
                         f' on PATH for --site {args.site}. Use --no-submit and '
                         'submit by hand, or run this on a login node.')
            out = subprocess.run([submit, str(script)], capture_output=True, text=True)
            if out.returncode != 0:
                sys.exit(f'ERROR: {Path(submit).name} failed for {script}: '
                         f'{out.stderr.strip()}')
            jobid = out.stdout.strip()
        word = 'trajectory' if count == 1 else 'trajectories'
        direction = ' backward' if args.backward else ''
        # Don't claim a plot on a host that cannot make one (Expanse has no
        # ase/matplotlib) -- the NOTE above already said so, and the two lines
        # disagreeing is how a summary line stops being read.
        plotting = ' '.join(pairs) if (pairs and plot_py) else 'none'
        print(f'{jobid}  ({base}.milo, {count}{direction} {word}, '
              f'{cpus} cpus, {int(mem)+4}G each, plot: {plotting})')

    if args.remote and args.wait:
        import remotejob
        remotejob.fetch(wait=True)


if __name__ == '__main__':
    main()
