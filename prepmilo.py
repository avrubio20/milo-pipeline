#!/usr/bin/env python3
"""
prepmilo.py

Turn a Gaussian hpmodes frequency calculation into a ready-to-run Milo input,
and optionally fan it out into a seeded ensemble.

    prepmilo.py -i freq/DA_ts.out -o DA_fwd --fs 100
    prepmilo.py -i freq/DA_ts.out -o DA_fwd --fs 200 -n 100
    prepmilo.py -i freq/DA_ts.out -o DA_fwd.in --fs 100 --phase 1-5

Wraps Milo's own parse_frequencies.py and setup_ensemble.py; this script only
fills in the $job section and picks the phase pair. Hand the result to
runmilo.py.

Note on -n: it is the number of *trajectories*, matching Milo's
setup_ensemble.py. Trajectory length is --fs.
"""
from __future__ import annotations

import argparse
import functools
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path

@functools.lru_cache(maxsize=1)
def milo_home() -> Path:
    """Where Milo lives, from the config runmilo.py reads. Resolved on first
    use, so --help works without an installation."""
    from runmilo import CONFIG_PATH, load_config     # installed side by side
    home = os.environ.get('MILO_HOME') or load_config().get('milo_home')
    if not home:
        sys.exit('ERROR: Milo\'s location is not recorded. Run install_milo.sh, '
                 f'or write `milo_home = <path>` into {CONFIG_PATH}, '
                 'or export MILO_HOME.')
    return Path(os.path.expandvars(home))


LIGHT = {'H', 'D'}  # skipped when auto-picking the phase pair


SUMMARY = """Turn a Gaussian freq=hpmodes transition state into a Milo input.

Works out the trajectory length, the reaction coordinate and which bonds to
follow, then writes a .in file for runmilo.py. The bonds it finds are stamped
into the file, so runmilo.py and milosum.py need no flags afterwards."""

EXAMPLES = """examples:
  prepmilo.py -i freq/TS.out -o RUN                  200 fs, 8 cpus, 12 GB
  prepmilo.py -i freq/TS.out -o RUN --fs 500         a longer trajectory
  prepmilo.py -i freq/TS.out -o RUN --phase 3-7      pick the bond yourself

then:
  runmilo.py RUN.in --traj 1                         one, to see it work
  runmilo.py RUN.in --traj 100 --force               the ensemble
"""


def parse_args():
    p = argparse.ArgumentParser(
        description=SUMMARY, epilog=EXAMPLES,
        formatter_class=argparse.RawDescriptionHelpFormatter)

    io = p.add_argument_group('input and output')
    io.add_argument('-i', '--input', required=True,
                    help='the Gaussian freq=hpmodes output for your transition '
                         'state. Ordinary freq output will not do: Milo needs '
                         'the high-precision normal modes.')
    io.add_argument('-o', '--out', required=True,
                    help='name for the Milo input; "RUN" and "RUN.in" both work')
    io.add_argument('--force', action='store_true',
                    help='replace an existing output instead of refusing')

    traj = p.add_argument_group('the trajectory')
    traj.add_argument('--fs', type=float, default=200.0,
                      help='length in femtoseconds (default: 200). Long enough '
                           'that the trajectory commits to products or back to '
                           'reactants.')
    traj.add_argument('--step', type=float, default=1.0,
                      help='step size in fs (default: 1.0)')
    traj.add_argument('--phase', default='auto',
                      help='the atom pair that defines the reaction coordinate, '
                           'as i-j, 1-based. Default auto: the heavy-atom pair '
                           'moving most along the imaginary mode. Override it '
                           'when that pair is not the bond you care about -- the '
                           'ranking is printed either way, so you can check.')
    traj.add_argument('--direction', default='bring_together',
                      choices=['bring_together', 'push_apart'],
                      help='which way along the imaginary mode to start '
                           '(default: bring_together)')
    traj.add_argument('--temp', type=float, default=298.15,
                      help='temperature in kelvin for the initial conditions '
                           '(default: 298.15)')

    res = p.add_argument_group('resources, written into the input file')
    res.add_argument('-p', '--processors', '--cpus', type=int, default=8,
                     help='cpus per trajectory (default: 8). Measured on a '
                          '16-atom system: 8 is near the knee, and 24 is slower '
                          'than 16. Bigger systems use more cores better.')
    res.add_argument('-m', '--memory', '--mem', type=int, default=12,
                     help='GB for Gaussian %%mem (default: 12). runmilo.py asks '
                          'the scheduler for a little more than this.')

    legacy = p.add_argument_group('legacy')
    legacy.add_argument('-n', '--trajectories', type=int, default=None,
                        help="Milo's own way of making an ensemble: N copies, "
                             'each with a seed written in. runmilo.py does not '
                             'want these -- it runs one input as an array and '
                             'each member seeds itself. Here because it is '
                             "Milo's documented idiom, not because you need it.")
    return p.parse_args()


def run_parse_frequencies(freq_out: Path) -> str:
    """Call Milo's parser and return the input file it produces."""
    with tempfile.TemporaryDirectory() as tmp:
        dest = Path(tmp) / 'raw.in'
        r = subprocess.run(
            [sys.executable, str(milo_home() / 'milo_1_0_3/tools' / 'parse_frequencies.py'),
             str(freq_out), str(dest)],
            capture_output=True, text=True, env={'PYTHONPATH': str(milo_home()), 'PATH': ''},
        )
        if r.returncode != 0:
            msg = (r.stderr.strip().splitlines() or ['unknown error'])[-1]
            if 'hpmodes' in msg:
                sys.exit(f'ERROR: {freq_out} is not a high-precision frequency '
                         'calculation.\nRe-run the Gaussian job with '
                         "'freq=(hpmodes,noraman)' — Milo cannot use the "
                         'standard-precision normal modes.')
            sys.exit(f'ERROR: parse_frequencies.py failed on {freq_out}:\n{msg}')
        return dest.read_text()


def section(text: str, name: str) -> str:
    m = re.search(rf'\${name}\n(.*?)\$end', text, re.S)
    return m.group(1) if m else ''


def auto_phase(text: str) -> tuple[str, list[tuple[str, float]]]:
    """Pick the heavy-atom pair whose distance changes most along mode 0.

    That mode is the reaction coordinate; the pair that moves most along it is
    the least ambiguous sensor for which way the trajectory is headed.
    """
    import numpy as np
    mol = [l.split() for l in section(text, 'molecule').strip().split('\n')[1:] if l.strip()]
    sym = [r[0] for r in mol]
    X = np.array([[float(v) for v in r[1:4]] for r in mol])
    row = section(text, 'frequency_data').strip().split('\n')[0].split()
    if float(row[0]) >= 0:
        sys.exit('ERROR: the first mode is not imaginary — this is not a transition '
                 'state, or the frequency job converged to a minimum.')
    D = np.array([float(v) for v in row[3:]]).reshape(-1, 3)

    ranked = []
    for i in range(len(sym)):
        for j in range(i + 1, len(sym)):
            if sym[i] in LIGHT or sym[j] in LIGHT:
                continue
            d0 = np.linalg.norm(X[i] - X[j])
            d1 = np.linalg.norm((X[i] + D[i]) - (X[j] + D[j]))
            ranked.append((f'{i+1}-{j+1}', d1 - d0))
    ranked.sort(key=lambda t: -abs(t[1]))
    return ranked[0][0], ranked[:4]


def moving_pairs(ranked: list[tuple[str, float]]) -> list[str]:
    """Every heavy-atom pair moving with the reaction coordinate, not just the
    one `phase` can name. A Diels-Alder TS has two forming bonds of equal
    magnitude and opposite-signed spectators, so keeping those within 10% of the
    largest displacement, and only in the same direction, picks out exactly the
    bonds worth plotting and classifying downstream."""
    if not ranked:
        return []
    top = ranked[0][1]
    return [pair for pair, delta in ranked
            if delta * top > 0 and abs(delta) >= 0.9 * abs(top)][:4]


def job_section(args, pair: str, pairs: list[str]) -> str:
    header = re.search(r'gaussian_header\s+(.*)', args._raw).group(1).strip()
    i, j = pair.split('-')
    # Stamped so runmilo.py and milosum.py do not need --pairs: `phase` can name
    # only one bond, and a cycloaddition forms two. Milo strips in-line comments
    # before parsing, so this line is invisible to it.
    stamp = f'    # pairs {" ".join(pairs)}\n' if pairs else ''
    return (f'$job\n'
            + stamp +
            f'    gaussian_header         {header}\n'
            f'    program                 gaussian16\n'
            f'    step_size               {args.step:.2f}\n'
            f'    max_steps               {round(args.fs / args.step)}\n'
            f'    temperature             {args.temp}\n'
            f'    phase                   {args.direction} {i} {j}\n'
            f'    memory                  {args.memory}\n'
            f'    processors              {args.processors}\n'
            f'    random_seed             generate\n'
            f'$end\n')


def main():
    args = parse_args()
    freq_out = Path(args.input)
    if not freq_out.is_file():
        sys.exit(f'ERROR: input file not found: {freq_out}')
    out = Path(args.out if args.out.endswith('.in') else f'{args.out}.in')
    if out.exists() and not args.force:
        sys.exit(f'ERROR: refusing to overwrite {out.resolve()}. '
                 'Re-run with --force if you mean to replace it.')

    args._raw = run_parse_frequencies(freq_out)

    if args.phase == 'auto':
        pair, ranked = auto_phase(args._raw)
        pairs = moving_pairs(ranked)
        print('phase pair (auto) — distance change along the imaginary mode:')
        for name, delta in ranked:
            mark = '   <- chosen' if name == pair else (
                '   <- also followed' if name in pairs else '')
            print(f'    {name:<8} {delta:+.3f} A{mark}')
    else:
        pair = args.phase
        if not re.fullmatch(r'\d+-\d+', pair):
            sys.exit(f"ERROR: --phase must look like '1-5', got {pair!r}")
        pairs = [pair]

    body = args._raw[args._raw.index('$comment'):]
    out.write_text(job_section(args, pair, pairs) + '\n' + body)
    steps = round(args.fs / args.step)
    print(f'\nWrote {out.resolve()}')
    print(f'  {steps} steps x {args.step:g} fs = {args.fs:g} fs')
    print(f'  phase     = {args.direction} {pair.replace("-", " ")}')
    print(f'  bonds     = {" ".join(pairs)}  (followed by runmilo/milosum; '
          'override with --pairs)')
    print(f'  resources = {args.processors} cpus, {args.memory} GB')

    if args.trajectories:
        r = subprocess.run(
            [sys.executable, str(milo_home() / 'milo_1_0_3/tools' / 'setup_ensemble.py'),
             '-n', str(args.trajectories), '-f', str(out), '--no_script'],
            capture_output=True, text=True, env={'PYTHONPATH': str(milo_home()), 'PATH': ''},
        )
        if r.returncode != 0:
            sys.exit(f'ERROR: setup_ensemble.py failed:\n{r.stderr.strip()}')
        made = sorted(out.parent.glob(f'{out.stem}_*.in'))
        print(f'\nEnsemble: {len(made)} seeded copies ({made[0].name} ...)')
        print('NOTE: runmilo.py does not want these. One input serves the whole '
              'ensemble -- each array member seeds itself. Submit the single '
              f'{out.name} with --traj instead; these copies carry explicit '
              'seeds and would run the identical trajectory N times.')
    print(f'\nSubmit with:  runmilo.py {out.name} --traj <N>')


if __name__ == '__main__':
    main()
