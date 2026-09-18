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
the site (Slurm's `ClusterName`, else `SGE_ROOT`) and emits `#SBATCH` or `#$`
directives accordingly; `--site` overrides it. Forking the tools per cluster
would mean fixing every future bug three times, which is what the `clusters/`
folders are deliberately *not* for: they hold paths, notes and deploy commands,
and nothing that can drift.

## Where it has been run

| machine | scheduler | scripts | Milo |
|---|---|---|---|
| Slurm workstation | Slurm | `~/bin` | `~/Programs/milo` |
| Expanse (SDSC) | Slurm | `~/bin` | `~/Programs/milo` |
| Hoffman2 (UCLA) | UGE | `~/Scripts` | `~/Programs/milo-1.0.3` |

Same chemistry, same test suites passing on all three (2026-09-14).
Adding a cluster means adding a `SITES` entry in `runmilo.py`, not a second
generator.

## Environment variables

| variable | does |
|---|---|
| `MILO_HOME` | where Milo itself lives, if not the default for your site |
| `MILO_SCRATCH` | scratch root for the job, if not the site default |
| `MILO_ACCOUNT` | Slurm account to bill (Expanse and similar) |

## Before changing anything

Run both suites. They are the oracle, they need no scheduler, and they take two
seconds:

    bash test_runmilo.sh && bash test_milosum.sh
