# Milo direct-dynamics pipeline

Quasiclassical direct-dynamics trajectories from a Gaussian transition state,
run as an ensemble, on whichever machine you are on.

    prepmilo.py -i freq/TS.out -o RUN --fs 200 -p 8 -m 12   # g16 hpmodes -> Milo input
    runmilo.py  RUN.in --traj 1                             # one test trajectory
    runmilo.py  RUN.in --traj 100 --force                   # the ensemble
    milosum.py  RUN.in                                      # outcomes + branching ratio

These are wrappers around [Milo 1.0.3](https://github.com/DanielEss-lab/milo),
which they download for you. Milo itself is not modified or vendored here.

**New here? Read [INSTALL.md](INSTALL.md).** It walks through a first install on
a cluster from scratch, assuming no prior experience with either.

    ./install_milo.sh --prefix ~/milo --add-path

installs Milo and the tools under one directory of your choosing and records
where they went, so nothing below has a path compiled into it.

## Layout

    install_milo.sh   put all of this, and Milo itself, on an account
    runmilo.py        submit an ensemble as one job array (Slurm or UGE)
    milosum.py        inventory, classify, branching ratio with a Wilson interval
    prepmilo.py       Gaussian freq=hpmodes -> a Milo input, with the bonds stamped in
    plot_traj.py      per-trajectory distance/energy plot (needs ase + matplotlib)
    milo_movie.py     trajectory animation
    test_runmilo.sh   30 checks, ~2 s, no scheduler needed
    test_milosum.sh   19 checks, ~2 s
    examples/         a ready-to-run Diels-Alder input
    clusters/         per-machine notes and deploy scripts

**There is one copy of every tool, not one per machine.** `runmilo.py` detects
the scheduler (`SGE_ROOT` means UGE, else Slurm) and emits `#$` or `#SBATCH`
directives accordingly; `--scheduler` overrides it. Forking the tools per
cluster would mean fixing every future bug three times, which is what the
`clusters/` folders are deliberately *not* for: they hold notes and deploy
commands, and nothing that can drift.

## Where things go

You choose, with `--prefix` and the overrides under `install_milo.sh --help`:

    PREFIX/bin/                 the four tools
    PREFIX/opt/milo-1.0.3/      Milo itself
    ~/.milo.conf                what you chose, which the tools read back

Nothing is hardcoded to a machine. Run on a Slurm workstation, Expanse and
Hoffman2 (UGE), same chemistry and the same suites passing on all three.
Supporting another cluster means editing the config, not the code.

## Environment variables

These override the config file for one run; normally you need none of them.

| variable | does |
|---|---|
| `MILO_CONF` | the config file to read (default `~/.milo.conf`) |
| `MILO_HOME` | where Milo itself lives |
| `MILO_SCRATCH` | scratch root for the job |
| `MILO_ACCOUNT` | scheduler account to bill |

## Before changing anything

Run both suites. They are the oracle, they need no scheduler, and they take two
seconds:

    bash test_runmilo.sh && bash test_milosum.sh
