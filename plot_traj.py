#!/usr/bin/env python3
"""Plot forming-bond distances (and SCF energy) against time for a Milo trajectory.

    ./plot_traj.py results/DA_run_001/DA_run_001.xyz --pairs 1-5 4-6
    ./plot_traj.py results/DA_run_001/DA_run_001.xyz --pairs 1-5 4-6 \
                   --energy results/DA_run_001/DA_run_001.out

runmilo.py already plots each member as it finishes; this is for re-plotting.

Atom indices are 1-based, matching Gaussian and the $molecule section.
Frames carrying t_fs in the extxyz comment (written by the stitching step) are
plotted on that axis; otherwise time is the frame index.
"""
from __future__ import annotations

import argparse
import re
from pathlib import Path

import ase.io
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt

FORMED = 1.7  # angstrom; a C-C bond is committed below this. Element-specific --
              # raise it for longer bonds (C-S ~2.2) before reading a gap time.


def parse_args():
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument('xyz', help='Milo trajectory .xyz')
    p.add_argument('--pairs', nargs='+', required=True,
                   help="1-based atom pairs, e.g. 1-5 4-6")
    p.add_argument('--energy', default=None,
                   help='Milo .out to read SCF energies from (adds a second panel)')
    p.add_argument('--formed', type=float, default=FORMED,
                   help=f'bond-formed threshold in angstrom (default: {FORMED})')
    p.add_argument('-o', '--out', default=None, help='output png (default: <xyz>.png)')
    return p.parse_args()


def scf_energies(path: Path):
    """SCF energies in kcal/mol relative to the first step."""
    text = path.read_text()
    e = [float(x) * 627.509 for x in
         re.findall(r'SCF Energy:\s*\n\s*(-?\d+\.\d+)', text)]
    return [x - e[0] for x in e] if e else []


def main():
    args = parse_args()
    frames = ase.io.read(args.xyz, ':')
    pairs = [tuple(int(n) for n in p.split('-')) for p in args.pairs]
    time = [f.info.get('t_fs', i) for i, f in enumerate(frames)]

    energies = scf_energies(Path(args.energy)) if args.energy else []
    nrows = 2 if energies else 1
    fig, axes = plt.subplots(nrows, 1, figsize=(7, 3.2 * nrows), sharex=True,
                             squeeze=False)
    ax = axes[0][0]

    crossings = {}
    for i, j in pairs:
        d = [f.get_distance(i - 1, j - 1) for f in frames]
        ax.plot(time, d, lw=1.6, label=f'{frames[0].symbols[i-1]}{i}-'
                                       f'{frames[0].symbols[j-1]}{j}')
        below = [t for t, x in zip(time, d) if x < args.formed]
        if below:
            crossings[(i, j)] = below[0]

    ax.axhline(args.formed, color='0.6', ls=':', lw=1)
    ax.set_ylabel('distance (Å)')
    ax.legend(frameon=False)
    if 't_fs' in frames[0].info:
        ax.axvline(0, color='0.6', ls='--', lw=1)
        ax.text(0, ax.get_ylim()[1], ' TS', va='top', fontsize=8, color='0.4')

    if energies:
        axes[1][0].plot(time[:len(energies)], energies, lw=1.6, color='C3')
        axes[1][0].set_ylabel('SCF energy (kcal/mol)')
    axes[-1][0].set_xlabel('time (fs)')

    out = args.out or Path(args.xyz).with_suffix('.png')
    fig.tight_layout()
    fig.savefig(out, dpi=150)
    print(f'wrote {out}')

    if len(crossings) == 2:
        (a, b), (c, d) = crossings.items()
        print(f'  {a[0]}-{a[1]} formed at {b:g} fs, {c[0]}-{c[1]} at {d:g} fs '
              f'-> gap {abs(b - d):g} fs')
    for pair in pairs:
        if pair not in crossings:
            print(f'  {pair[0]}-{pair[1]} never reached {args.formed} Å '
                  '- trajectory too short, or that bond does not form')


if __name__ == '__main__':
    main()
