# Hoffman2 (UCLA IDRE)

    ssh <your-user>@hoffman2.idre.ucla.edu

**Scheduler: UGE 8.6.4** (`qsub`, `#$` directives, `$SGE_TASK_ID`). `runmilo.py`
detects this automatically through `SGE_ROOT`; `--site hoffman2` forces it.

## Paths

| what | where |
|---|---|
| Milo | `PREFIX/opt/milo-1.0.3` |
| scripts | wherever you pointed `--prefix` |
| scratch | `$TMPDIR` per job, node-local, removed by UGE |
| test runs | wherever you submit from |

Install where you like: `./install_milo.sh --prefix /u/project/<group>/milo`
puts it in a group directory, `--prefix ~/milo` keeps it in your home. Home is
the default because group directories are often readable only by members of
that unix group.

## Setting up a new account

    ./install_milo.sh --check        # qsub, gaussian group, modules, tests
    ./install_milo.sh --add-path     # install + write the PATH line
    ./install_milo.sh --example      # ./milo_example/DA_example.in
    cd milo_example && runmilo.py DA_example.in --traj 1

`--check` is the one to run first. The failure it exists for: **you must be in
the `gaussian` unix group** or Gaussian will not run, and without the check you
find that out ten minutes into a queued job.

## What the generated script does here

- `#$ -cwd -N <job> -o joblogs/joblog.$JOB_NAME.$JOB_ID.$TASK_ID -j y -notify`
- `#$ -pe shared* <cpus>` and one combined `-l` line in the Gsub.py idiom:
  `h_data` **per slot**, `h_vmem` per slot x slots, `h_rt`/`s_rt` in seconds,
  `arch=intel*`, plus `highp` past 24 h (which is what puts a job on Houk nodes).
- `#$ -t 1-N` with `-tc K` for `--array-limit`. UGE's `-t` takes one range, not
  a comma list, so a backward ensemble with a hole carries a `MEMBERS` roster
  and members outside it step aside.
- `#$ -notify` means UGE sends **SIGUSR1** at `s_rt`, ~5 min before the hard
  limit. That is trapped alongside INT/TERM to stage results back.
- `module load gaussian` (G16 C.02 avx) and `module load python/3.9.6` -- the
  module, deliberately, because the login `python3` on Aris's account is a
  personal conda env a student will not have.

## Measured

16-atom Diels-Alder, wb97xd/6-31G*, 50 steps, 8 cpus / 12 GB: ~10-11 min per
trajectory, ~11 min queued in `pod_short.q`. Slower per trajectory than Expanse
(~6.5 min) -- different CPU generation, not a misconfiguration.

## Deploy from the workstation

    clusters/hoffman2/deploy.sh    # rsync the tools up, then run both suites there

The `hoffman2` name is an SSH alias; set `MILO_HOFFMAN2_HOST=<user>@hoffman2.idre.ucla.edu`
if you have not configured one in `~/.ssh/config`.
