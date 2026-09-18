"""
milo_movie.py -- PyMOL scene + renderer for a Milo trajectory.

PyMOL perceives connectivity once, from the first state, and never again --
verified: a 101-state load reports 14 bonds in state 1 and 14 in state 101,
and `discrete=1` makes it worse (0 bonds in the last state). So a forming bond
will never appear on its own. This script re-evaluates the named pairs before
rendering each frame and calls bond/unbond, so the stick appears exactly when
the bond forms.

    # headless, writes frames + mp4
    pymol -cq milo_movie.py -- results/DA_run_001/DA_run_001.xyz 1-5 4-6

    # or inside a session, to set the scene up and look at it
    run milo_movie.py
    miloscene results/DA_run_001/DA_run_001.xyz, 1-5 4-6
    smoothmd 5, adaptive          # UltimateSmoothMD6, if you want it

Not installed by install_milo.sh and not part of the pipeline: it needs PyMOL,
numpy, and a workstation-local style script (~/bin/pymol/arismol.py). It is
here because trajectories are worth watching, not because anything depends on
it.
"""
import os
import subprocess
import sys

from pymol import cmd

FONT = '/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf'
BONDED = 1.80   # angstrom; below this the pair is drawn as a solid stick
OBJ = 'traj'


def _pairs(spec):
    return [tuple(int(n) for n in p.split('-')) for p in spec]


def miloscene(xyz, pairs='', bonded=BONDED, style='arismol', step_fs=1.0):
    """Load a trajectory and set up the scene. pairs: '1-5 4-6'."""
    import numpy as np

    pairs = _pairs(pairs.split()) if isinstance(pairs, str) else pairs
    cmd.delete('all')
    cmd.load(xyz, OBJ)

    if style:
        # arismol = houkmol's cel-shaded look with xyzrender's CPK palette.
        cmd.do('run %s' % os.path.expanduser('~/bin/pymol/arismol.py'))
        cmd.do('arismol')
        cmd.do('ballnstick %s' % OBJ)

    # Black dashed measurement lines. BallnStick sets dash_gap 0.01, which is a
    # solid line -- override it here or the "dashes" render as sticks.
    cmd.set('dash_color', 'black')
    cmd.set('dash_radius', 0.025)
    cmd.set('dash_gap', 0.22)
    cmd.set('dash_length', 0.14)
    cmd.set('label_size', 20)
    cmd.set('label_color', 'black')
    cmd.set('label_distance_digits', 2)

    for i, j in pairs:
        name = f'd{i}_{j}'
        cmd.distance(name, f'{OBJ} and id {i}', f'{OBJ} and id {j}')
        cmd.show('dashes', name)
        cmd.show('labels', name)

    # One orientation for the whole movie: orient on the last state, where the
    # ring is closed, so the product does not drift out of frame.
    n = cmd.count_states(OBJ)
    cmd.frame(n)
    cmd.orient(OBJ)
    cmd.turn('x', -15)
    cmd.zoom(OBJ, 1.4, complete=1)

    # Push each label sideways, off the bond it measures. Which side is
    # "outward" depends on the camera, so project the midpoint through the
    # current view rotation and offset along screen x.
    rot = np.array(cmd.get_view()[:9]).reshape(3, 3)
    coords = np.array(cmd.get_coords(OBJ, n))
    centre = coords.mean(axis=0)
    for i, j in pairs:
        mid = (coords[i - 1] + coords[j - 1]) / 2.0
        screen_x = rot.dot(mid - centre)[0]
        # Sign is inverted relative to the view matrix: PyMOL's label_position
        # +x moves the label toward screen left here. Verified by rendering
        # both signs -- negative puts each label outboard of its own bond.
        cmd.set('label_position', (-2.2 if screen_x >= 0 else 2.2, 0.0, 0.5),
                f'd{i}_{j}')

    cmd.frame(1)
    return pairs


def _set_bonds(pairs, state, bonded):
    """Solid stick once the pair is within `bonded`; dashed while it forms.

    The distance object stays enabled either way so the number is readable for
    the whole trajectory -- only the dashes are hidden once the stick is drawn,
    since the two would otherwise overlap.
    """
    for i, j in pairs:
        name = f'd{i}_{j}'
        d = cmd.get_distance(f'{OBJ} and id {i}', f'{OBJ} and id {j}', state=state)
        # unbond first: `bond` does not check for an existing record, so
        # repeated calls stack duplicates.
        cmd.unbond(f'{OBJ} and id {i}', f'{OBJ} and id {j}')
        if d < bonded:
            cmd.bond(f'{OBJ} and id {i}', f'{OBJ} and id {j}')
            cmd.hide('dashes', name)
        else:
            cmd.show('dashes', name)
        cmd.enable(name)
        cmd.show('labels', name)


def milomovie(xyz, pairs='', outdir=None, fps=20, width=900, height=700,
              bonded=BONDED, step_fs=1.0, gif=1):
    """Scene + render every state + encode mp4 (needs ffmpeg on PATH)."""
    xyz = os.path.abspath(xyz)
    pairs = miloscene(xyz, pairs, bonded, step_fs=float(step_fs))
    # PyMOL chdir's to the script's directory, so a relative outdir would land
    # next to this file. Default beside the trajectory instead.
    outdir = os.path.abspath(outdir) if outdir else os.path.join(
        os.path.dirname(os.path.dirname(xyz)), 'movie')
    os.makedirs(outdir, exist_ok=True)
    n = cmd.count_states(OBJ)
    for s in range(1, n + 1):
        cmd.frame(s)
        _set_bonds(pairs, s, float(bonded))
        cmd.png(os.path.join(outdir, 'f%04d.png' % s),
                width=int(width), height=int(height), ray=1, quiet=1)
    print(f'rendered {n} frames to {outdir}')

    base = os.path.splitext(os.path.basename(xyz))[0]
    mp4 = os.path.join(outdir, base + '.mp4')
    # The timestamp is burned in by ffmpeg, not drawn by PyMOL: PyMOL's
    # screen-anchored labels (label_relative_mode 2) are an OpenGL-only
    # feature and the ray tracer silently drops them, so a pseudoatom clock
    # renders as nothing in the frames.
    clock = ("drawtext=fontfile=%s:text='%%{eif\\:n*%g\\:d} fs'"
             ":x=30:y=22:fontsize=34:fontcolor=black" % (FONT, float(step_fs)))
    if subprocess.run(['ffmpeg', '-y', '-loglevel', 'error',
                       '-framerate', str(fps), '-i', os.path.join(outdir, 'f%04d.png'),
                       '-vf', clock, '-pix_fmt', 'yuv420p', mp4]).returncode == 0:
        print('wrote', mp4)
        if int(gif):
            # Two-pass palette: a GIF is 256 colours, and the default single
            # global palette bands the cel-shaded greys badly.
            g = os.path.join(outdir, base + '.gif')
            pal = ('fps=%d,scale=700:-1:flags=lanczos,split[a][b];'
                   '[a]palettegen=stats_mode=diff[p];[b][p]paletteuse='
                   'dither=bayer:bayer_scale=3' % int(fps))
            if subprocess.run(['ffmpeg', '-y', '-loglevel', 'error', '-i', mp4,
                               '-vf', pal, '-loop', '0', g]).returncode == 0:
                print('wrote', g)
        for f in os.listdir(outdir):
            if f.startswith('f') and f.endswith('.png'):
                os.remove(os.path.join(outdir, f))
    else:
        print('ffmpeg failed; PNG frames kept in', outdir, file=sys.stderr)


cmd.extend('miloscene', miloscene)
cmd.extend('milomovie', milomovie)

# Headless:  pymol -cq milo_movie.py -- <xyz> <pair> [<pair> ...]
# Gate on the `--` separator. A bare `run milo_movie.py` inside a GUI session
# must only register the commands: an earlier version scanned all of sys.argv,
# so loading it interactively kicked off a full render with the session's own
# launch arguments and silently overwrote the movie.
# PyMOL strips the `--` and leaves sys.argv = [script, args...], so gate on
# argv[0] being this file: inside a GUI session argv[0] is whatever launched
# PyMOL, never milo_movie.py.
if len(sys.argv) > 1 and os.path.basename(sys.argv[0]) == 'milo_movie.py':
    milomovie(sys.argv[1], ' '.join(sys.argv[2:]))
