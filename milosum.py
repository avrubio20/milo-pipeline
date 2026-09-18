#!/usr/bin/env python3
"""
milosum.py

Summarise a Milo trajectory ensemble: what finished, where each trajectory
ended up, and the branching ratio with an honest error bar.

    milosum.py DA_fwd.in                      # inventory + outcomes
    milosum.py DA_fwd.in --pairs 1-5 4-6      # the two forming bonds
    milosum.py DA_fwd.in --json > summary.json

The expected member count comes from the `#SBATCH --array=` line of the
generated <base>_milo.sh, not from whatever happens to be in results/. A bare
glob would compute a ratio over the members that survived and report it as if
it were the whole ensemble, which is the one number in this pipeline that must
never be quietly wrong. --expect covers a hand-submitted ensemble.

A forward member and its --backward partner are the two halves of ONE sample:
they share a seed and describe a single trajectory through the transition
state. When backward results exist, samples are counted as pairs and the
outcome is written reverse->forward (reactant->product is a reactive event);
the confidence interval is over those pairs, never over 2N halves.

Classification (the criterion, and why):

    formed   d < --formed A   (default 1.7, the value plot_traj.py draws)
    broken   d > --broken A   (default 3.0, past van der Waals contact)

A bond commits the first time it crosses a threshold and stays committed until
it crosses the other one -- the gap between the two is deliberate. Forming C-C
bonds in these trajectories ring hard: a Diels-Alder member here bottoms out at
1.28 A and relaxes back to 1.84 A while unambiguously bonded, so any
single-frame test (including "the last frame") misclassifies it. Hysteresis is
what makes the call stable; it is also what lets a real recrossing be seen,
since a bond that goes formed -> broken had to traverse 1.3 A of separation to
do it.

    product    every pair committed formed
    reactant   every pair committed broken
    stepwise   one pair formed, another broken -- a one-bond species, the
               interesting outcome; never silently folded into product
    undecided  some pair never committed (the trajectory ran out of steps)

For a product, the gap time |t(bond A formed) - t(bond B formed)| is reported:
that is the dynamical concertedness measure, and it is what the ensemble is
usually being run to get.
"""
from __future__ import annotations

import argparse
import json
import math
import re
import statistics
import sys
from pathlib import Path

FORMED = 1.7
BROKEN = 3.0
CLASSES = ('product', 'reactant', 'stepwise', 'undecided')


def parse_args():
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument('input', help='the Milo input file the ensemble ran from')
    p.add_argument('--pairs', nargs='+', default=None,
                   help='1-based atom pairs to follow, e.g. 1-5 4-6 '
                        '(default: the pair named by `phase`)')
    p.add_argument('--formed', type=float, default=FORMED,
                   help=f'bond-formed threshold, angstrom (default: {FORMED})')
    p.add_argument('--broken', type=float, default=BROKEN,
                   help=f'bond-broken threshold, angstrom (default: {BROKEN})')
    p.add_argument('--expect', type=int, default=None,
                   help='expected member count, if <base>_milo.sh is gone')
    p.add_argument('--min-complete', type=float, default=0.9,
                   help='refuse to report a branching ratio below this '
                        'completeness fraction (default: 0.9)')
    p.add_argument('--json', action='store_true', help='machine-readable output')
    args = p.parse_args()
    # Overlapping thresholds make the committed state depend on which frame
    # happened to land in the overlap, i.e. on parity rather than on chemistry.
    if not args.formed < args.broken:
        p.error(f'--formed {args.formed} must be less than --broken '
                f'{args.broken}; the gap between them is the hysteresis.')
    if not 0 < args.formed < math.inf:
        p.error(f'--formed {args.formed} is not a positive distance')
    return args


# --- reading -----------------------------------------------------------------

def frames(xyz: Path) -> list[tuple[float, list[tuple[float, float, float]]]]:
    """[(t_fs, coords)] from a Milo .xyz. Comment lines read `Step 3: 3.0 fs`."""
    lines = xyz.read_text().splitlines()
    out, i = [], 0
    while i < len(lines):
        if not lines[i].strip():
            i += 1
            continue
        n = int(lines[i].split()[0])
        m = re.search(r'(-?[\d.]+)\s*fs', lines[i + 1])
        t = float(m.group(1)) if m else float(len(out))
        out.append((t, [tuple(float(x) for x in l.split()[1:4])
                        for l in lines[i + 2:i + 2 + n]]))
        i += 2 + n
    return out


def out_seed(out: Path) -> str | None:
    """The seed Milo recorded. Two halves are one sample because they share
    this, not because their filenames share an index."""
    lines = out.read_text(errors='replace').splitlines()
    for i, line in enumerate(lines[:-1]):
        if line.startswith('### Random Seed'):
            return lines[i + 1].strip()
    return None


def terminated_normally(out: Path) -> bool:
    """Milo's sign-off, in the last few lines where it belongs. A substring
    search anywhere would accept a concatenated .out whose successful run is
    followed by a crashed one."""
    tail = out.read_text(errors='replace').splitlines()[-5:]
    return any(line.startswith('Normal termination') for line in tail)


def member_files(name: str) -> tuple[Path | None, Path | None]:
    """A member's .out/.xyz, in its own directory or flat in results/.

    The flat form is the pre-2026-09-12 layout; ensembles run before the
    per-trajectory directories still have to be summarisable.
    """
    for stem in (Path('results') / name / name, Path('results') / name):
        out = stem.with_suffix('.out')
        xyz = stem.with_suffix('.xyz')
        out = out if out.is_file() else None
        xyz = xyz if xyz.is_file() else None
        if out or xyz:
            return out, xyz
    return None, None


def expected_members(base: str, rev: bool, override: int | None) -> list[int]:
    if override is not None:
        return list(range(1, override + 1))
    script = Path(f'{base}_rev_milo.sh' if rev else f'{base}_milo.sh')
    if not script.is_file():
        return []
    text = script.read_text()
    m = (re.search(r'^#SBATCH --array=([0-9,\-]+)', text, re.M)
         or re.search(r'^#\$ -t ([0-9,\-]+)', text, re.M))
    if not m:
        return []
    members = []
    for part in m.group(1).split(','):
        if '-' in part:
            lo, hi = part.split('-')
            members.extend(range(int(lo), int(hi) + 1))
        else:
            members.append(int(part))
    return sorted(members)


# --- classification ----------------------------------------------------------

def classify(traces: dict[str, list[tuple[float, float]]], formed: float,
             broken: float) -> dict:
    """Commit each bond with hysteresis, then name the terminus."""
    state, formed_at, recrossed = {}, {}, False
    for pair, series in traces.items():
        committed = None
        for t, d in series:
            if d < formed and committed != 'formed':
                recrossed = recrossed or committed == 'broken'
                committed = 'formed'
                formed_at.setdefault(pair, t)
            elif d > broken and committed != 'broken':
                recrossed = recrossed or committed == 'formed'
                committed = 'broken'
        state[pair] = committed
    values = list(state.values())
    if values and all(v == 'formed' for v in values):
        terminus = 'product'
    elif values and all(v == 'broken' for v in values):
        terminus = 'reactant'
    elif 'formed' in values and 'broken' in values:
        terminus = 'stepwise'
    else:
        terminus = 'undecided'
    gap = (max(formed_at.values()) - min(formed_at.values())
           if terminus == 'product' and len(formed_at) > 1 else None)
    return {'terminus': terminus, 'gap_fs': gap, 'recrossed': recrossed}


def read_half(name: str, pairs, formed, broken) -> dict:
    out, xyz = member_files(name)
    if out is None and xyz is None:
        failed = sorted(Path('results.failed').glob(f'{name}.*')) \
            if Path('results.failed').is_dir() else []
        return {'status': 'failed' if failed else 'missing'}
    if xyz is None or not xyz.stat().st_size:
        return {'status': 'incomplete'}
    normal = out is not None and terminated_normally(out)
    seed = out_seed(out) if out is not None else None
    steps = frames(xyz)
    # A pair naming an atom the trajectory does not have is either a wrong
    # --pairs or a truncated frame. Either way one bad member must not take the
    # whole summary down with a traceback -- it is inventory, like any other
    # way of being unreadable.
    natoms = len(steps[0][1]) if steps else 0
    if any(i > natoms or j > natoms for i, j in pairs):
        print(f'WARNING: {name} has {natoms} atom(s), but the bonds to follow '
              f'are {", ".join(f"{i}-{j}" for i, j in pairs)}. Skipping it.',
              file=sys.stderr)
        return {'status': 'malformed', 'seed': seed}
    traces = {f'{i}-{j}': [(t, math.dist(c[i - 1], c[j - 1])) for t, c in steps]
              for i, j in pairs}
    result = {'status': 'complete' if normal else 'incomplete', 'seed': seed}
    result.update(classify(traces, formed, broken))
    return result


# --- statistics --------------------------------------------------------------

def wilson(k: int, n: int, z: float = 1.96) -> tuple[float, float]:
    """Wilson score interval -- behaves at k=0, k=n and small n, unlike the
    normal approximation an ensemble of 100 trajectories would still abuse."""
    if n == 0:
        return (0.0, 1.0)
    p, d = k / n, 1 + z * z / n
    centre = (p + z * z / (2 * n)) / d
    half = z * math.sqrt(p * (1 - p) / n + z * z / (4 * n * n)) / d
    return (max(0.0, centre - half), min(1.0, centre + half))


def main():
    args = parse_args()
    path = Path(args.input if args.input.endswith('.in') else f'{args.input}.in')
    if not path.is_file():
        sys.exit(f'ERROR: {path} not found')
    base = path.stem
    text = path.read_text()

    pairs = args.pairs
    if not pairs:
        # The `# pairs` line prepmilo stamps into $job names every bond that
        # moves along the reaction coordinate; `phase` can only name one.
        m = re.search(r'^\s*#\s*pairs\s+([\d\s-]+)$', text, re.M)
        if m:
            pairs = m.group(1).split()
        else:
            m = re.search(r'^\s*phase\s+\w+\s+(\d+)\s+(\d+)', text, re.M)
            if not m:
                sys.exit('ERROR: no `# pairs` stamp, no `phase` pair, and no '
                         '--pairs. Name the bonds to follow.')
            pairs = [f'{m.group(1)}-{m.group(2)}']
            print(f'NOTE: no --pairs and no `# pairs` stamp; following the '
                  f'`phase` pair {pairs[0]} only.', file=sys.stderr)
    pairs = [tuple(int(n) for n in p.split('-')) for p in pairs]

    members = expected_members(base, False, args.expect)
    if not members:
        sys.exit(f'ERROR: no {base}_milo.sh to read the ensemble size from. '
                 'Pass --expect N -- summarising whatever is in results/ would '
                 'report a ratio over the survivors.')
    reverse = expected_members(base, True, None)
    # Reverse halves are discovered on disk as well as in the manifest. Trusting
    # the manifest alone means a deleted <base>_rev_milo.sh silently turns a
    # paired ensemble back into a forward-only one -- the sample unit changes
    # under you and everything still reads 100% complete.
    on_disk = set()
    if Path('results').is_dir():
        for entry in Path('results').iterdir():
            m = re.fullmatch(rf'{re.escape(base)}_(\d+)_rev', entry.stem)
            if m:
                on_disk.add(int(m.group(1)))
    if on_disk and not reverse:
        sys.exit(f'ERROR: results/ holds {len(on_disk)} reverse half/halves but '
                 f'there is no {base}_rev_milo.sh to say how many there should '
                 'be. Summarising now would silently report a forward-only '
                 'ensemble. Regenerate it with '
                 f'`runmilo.py {base}.in --backward --no-submit --force`.')
    # A reverse ensemble that is a SUBSET of the forward one is the normal
    # case: --backward only builds halves for members that actually finished,
    # so the ones missing a partner are simply incomplete samples. Only
    # reverse-only members are wrong -- they belong to no forward trajectory.
    extra = sorted(set(reverse) - set(members))
    if extra:
        sys.exit(f'ERROR: reverse member(s) {extra} have no forward member in '
                 f'{base}_milo.sh. They are halves of a trajectory that is not '
                 'part of this ensemble; pairs cannot be formed from two '
                 'different ensembles.')

    # A shrunk --traj leaves the old members on disk, outside the manifest.
    # Silently ignoring them is the same failure as summarising the survivors:
    # the inventory has to account for everything that is there.
    unexpected = []
    if Path('results').is_dir():
        for entry in Path('results').iterdir():
            m = re.fullmatch(rf'{re.escape(base)}_(\d+)', entry.stem)
            if m and int(m.group(1)) not in members:
                unexpected.append(int(m.group(1)))
    unexpected.sort()

    forward = {m: read_half(f'{base}_{m:03d}', pairs, args.formed, args.broken)
               for m in members}
    backward = {m: read_half(f'{base}_{m:03d}_rev', pairs, args.formed,
                             args.broken) for m in reverse}

    # A sample is a pair when the backward half was run, and a lone forward
    # trajectory otherwise. Counting halves would double the apparent N.
    paired = bool(reverse)
    samples, outcomes = {}, {}
    for m in members:
        halves = [forward[m]] + ([backward[m]] if m in backward else [])
        if paired and m not in backward:
            samples[m] = 'missing'
            continue
        if any(h['status'] != 'complete' for h in halves):
            samples[m] = next(h['status'] for h in halves
                              if h['status'] != 'complete')
            continue
        # The two halves are one sample because they share a seed. Matching
        # filename indices is an assumption about how they were produced; the
        # seed is the evidence. A mis-paired half would otherwise contribute a
        # perfectly plausible reverse->forward outcome.
        if paired and forward[m]['seed'] != backward[m]['seed']:
            samples[m] = 'seed-mismatch'
            print(f'WARNING: {base}_{m:03d} ran seed {forward[m]["seed"]} but '
                  f'its reverse half ran {backward[m]["seed"]}; they are not '
                  'two halves of one trajectory. Excluded from the ratio.',
                  file=sys.stderr)
            continue
        samples[m] = 'complete'
        outcomes[m] = ('->'.join([backward[m]['terminus'], forward[m]['terminus']])
                       if paired else forward[m]['terminus'])

    complete = sum(1 for s in samples.values() if s == 'complete')
    fraction = complete / len(members)
    # Zero-fill the four termini when samples are single trajectories: "0 of 100
    # stepwise, 95% CI [0, 3.7%]" is a real result about a channel you did not
    # see. Paired mode is left to observed outcomes -- the 16 combinations of
    # reverse->forward are mostly meaningless and would bury the real ones.
    tally = {c: 0 for c in CLASSES} if not paired else {}
    for outcome in outcomes.values():
        tally[outcome] = tally.get(outcome, 0) + 1
    # Same population as the branching ratio: a forward half whose partner is
    # missing is not in outcomes, so its gap time does not belong here either.
    gaps = [forward[m]['gap_fs'] for m in outcomes
            if forward[m].get('gap_fs') is not None]

    report = {
        'base': base,
        'pairs': [f'{i}-{j}' for i, j in pairs],
        'thresholds': {'formed': args.formed, 'broken': args.broken},
        'sample_unit': 'forward+backward pair' if paired else 'forward trajectory',
        'expected': len(members),
        'complete': complete,
        'complete_fraction': fraction,
        'by_status': {s: sum(1 for v in samples.values() if v == s)
                      for s in sorted(set(samples.values()))},
        'outcomes': tally,
        # Withheld, not just annotated: a refusal that still prints the ratio
        # is not a refusal. Anything scraping stdout or the JSON gets counts
        # and an explicit reason, and has to decide for itself.
        'fractions': {k: {'n': v, 'p': v / complete,
                          'ci95': wilson(v, complete)}
                      for k, v in tally.items()}
                     if complete and fraction >= args.min_complete else {},
        'gap_fs': {'median': statistics.median(gaps), 'min': min(gaps),
                   'max': max(gaps)} if gaps else None,
        'unexpected': unexpected,
        'recrossed': sorted(m for m in outcomes
                            if forward[m]['recrossed']
                            or backward.get(m, {}).get('recrossed')),
        'reported': complete > 0 and fraction >= args.min_complete,
    }
    if not report['reported']:
        report['withheld'] = (
            f'{complete}/{len(members)} complete, below --min-complete '
            f'{args.min_complete}' if complete else 'no complete samples')

    if args.json:
        json.dump(report, sys.stdout, indent=2)
        print()
    else:
        print(f'{base}: {complete}/{len(members)} complete ({fraction:.0%}); '
              f'one sample = one {report["sample_unit"]}')
        for status, n in sorted(report['by_status'].items()):
            if status != 'complete':
                print(f'  {status}: {n}')
        if unexpected:
            print(f'  outside the ensemble: {len(unexpected)} member(s) in '
                  f'results/ that {base}_milo.sh does not list: {unexpected} '
                  '-- not counted')
        print(f'  bonds {", ".join(report["pairs"])}; formed < {args.formed} A, '
              f'broken > {args.broken} A')
        for outcome, n in sorted(tally.items(), key=lambda kv: -kv[1]):
            if report['reported']:
                lo, hi = report['fractions'][outcome]['ci95']
                print(f'  {outcome:28s} {n:4d}  {n / complete:6.1%}  '
                      f'[{lo:.1%}, {hi:.1%}] 95% CI')
            else:
                print(f'  {outcome:28s} {n:4d}  (fraction withheld)')
        if report['gap_fs']:
            g = report['gap_fs']
            print(f'  gap time: median {g["median"]:g} fs '
                  f'(range {g["min"]:g}-{g["max"]:g})')
        if report['recrossed']:
            print(f'  recrossed: members {report["recrossed"]}')

    if not report['reported']:
        print(f'REFUSING to report a branching ratio: {complete}/{len(members)} '
              f'({fraction:.0%}) complete, below --min-complete '
              f'{args.min_complete:.0%}. The counts above are the inventory, '
              'not a result.', file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
