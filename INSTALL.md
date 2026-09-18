# Installing on a cluster, start to finish

This walks through a first install on UCLA's Hoffman2, which uses the UGE
scheduler (`qsub`). If you are on a Slurm cluster instead, everything below is
the same except the two monitoring commands — there is a short section at the
end with the differences.

You do not need to have installed scientific software before. Every command
here is one you can copy, and after each one there is a note on what you should
see and what to do if you see something else.

## What you are installing, and why it is two things

*Milo* is the program that actually runs the trajectories. It is written by the
Ess lab at BYU, and this install downloads version 1.0.3 of it unchanged.

*These scripts* are a layer on top of Milo that handles the parts Milo leaves to
you: turning a Gaussian frequency calculation into a Milo input, writing the
cluster submission script, running a hundred trajectories as one job instead of
a hundred, and summarising how they came out.

You install both in one step. Nothing you do here submits a job or costs
compute time — that stays your decision, later and explicitly.

## What you need first

- **An account on the cluster**, and the ability to log in over SSH.
- **Membership in the `gaussian` unix group.** Milo drives Gaussian 16 for the
  forces at every step, so without this nothing will run. On Hoffman2 you
  ask IDRE user support to add you, with your PI copied in to confirm you are
  covered by their Gaussian licence. The
  check in step 3 tells you whether you already have it, so run that first —
  finding out from a failed job ten minutes into the queue is the expensive way
  to learn it.
- **Eventually, a Gaussian `freq=hpmodes` output for your transition state.**
  Not needed to install: there is an example input included so you can do a
  complete run before you have your own.

## Step 1 — log in

    ssh <your-user>@hoffman2.idre.ucla.edu

You land on a login node. Login nodes are for editing, submitting and small
commands; anything that calculates goes to the queue. Nothing in this install
calculates, so all of it is fine to run here.

## Step 2 — get the code

    git clone https://github.com/<your-account>/milo-pipeline.git
    cd milo-pipeline

`git clone` copies this repository into a folder called `milo-pipeline` in your
home directory. If `git` is not found, run `module load git` first.

This folder is the *source*. The install copies out of it, so you can keep it
around, pull updates into it, and re-run the installer later.

## Step 3 — check the machine before installing

    ./install_milo.sh --check

This submits nothing and writes nothing. It looks for: `qsub`, your membership
in the `gaussian` group, a working `g16` after `module load gaussian`, the
`python/3.9.6` module, the four tools on your `PATH`, and Milo itself. Each line
comes back `ok`, `WARN` or `FAIL`.

On a fresh account, expect `FAIL` on the tools and on Milo — you have not
installed them yet, which is step 4. What you are reading this output for is
the `gaussian` group line and the `g16` line. If either of those fails, stop and
sort that out first; the rest of the install will succeed and then the first job
will fail.

## Step 4 — install

    ./install_milo.sh --add-path

This does four things and prints each one:

1. Downloads Milo 1.0.3 and unpacks it to `~/Programs/milo-1.0.3`.
2. Copies the four tools (`runmilo.py`, `milosum.py`, `prepmilo.py`,
   `plot_traj.py`) and the two test suites into `~/Scripts`.
3. Adds a line to your `~/.bashrc` putting `~/Scripts` on your `PATH`, so you
   can type `runmilo.py` from any folder instead of a full path.
4. Prints the commands to run next.

It will not overwrite a file that differs from its copy without `--force`, and
re-running it is safe — a second run reports that everything is already current.
`--dry-run` prints what it would do and touches nothing, if you would rather
look before it acts.

Leave off `--add-path` if you would rather edit `~/.bashrc` yourself; the script
prints the exact line to add.

## Step 5 — reload your shell and check again

    source ~/.bashrc
    ./install_milo.sh --check

`source ~/.bashrc` re-reads the startup file so the new `PATH` takes effect
without logging out. Everything should now be `ok`, including the two test
suites, which the check runs for you — they take about two seconds and need no
scheduler.

If `runmilo.py` still comes back "not on PATH", the `PATH` line did not take.
Check it is really in `~/.bashrc` (`tail ~/.bashrc`), then open a fresh login.

## Step 6 — one real trajectory, on the included example

    ./install_milo.sh --example
    cd milo_example
    runmilo.py DA_example.in --traj 1

`--example` writes `milo_example/DA_example.in`: a 16-atom Diels-Alder
transition state, 50 steps, at 8 cpus and 12 GB. It is small on purpose — about
ten minutes of compute — and it carries the bond pairs the summary needs, so
neither command below needs any flags.

`runmilo.py` writes a submission script called `DA_example_milo.sh` next to the
input and submits it. It prints the job id.

Watch it:

    qstat -u $USER

`qw` means queued and waiting, `r` means running, and an empty list means it is
done. The example usually waits about ten minutes before it starts.

When it finishes:

    milosum.py DA_example.in

You should get one complete trajectory, classified as `product` — the
Diels-Alder went over the barrier and formed both bonds. A summary that says
`product` is the install working end to end: Gaussian ran, Milo ran, the results
came back where they belong.

The files it left behind:

    results/DA_example_001/     the trajectory: .out, .xyz, and a .png if plotting is available
    joblogs/                    what the scheduler and the job printed
    results.failed/             only appears if something went wrong, and keeps everything needed to diagnose it

## Step 7 — your own system

Start from a Gaussian frequency calculation on your transition state, run with
`freq=hpmodes` (ordinary `freq` output does not carry enough digits in the
normal modes for Milo to sample them properly).

    prepmilo.py -i freq/TS.out -o RUN --fs 200 -p 8 -m 12

This reads the Gaussian output and writes `RUN.in`, a Milo input: 200 fs of
trajectory, 8 cpus, 12 GB. It also works out which atom pairs are moving in the
imaginary mode and stamps them into the file as a comment, so `milosum.py` later
knows which bonds to watch without being told.

Then the same two commands as the example, one test first:

    runmilo.py RUN.in --traj 1          # does one trajectory work?
    milosum.py RUN.in                   # did it do something chemically sensible?

and only then the ensemble:

    runmilo.py RUN.in --traj 100 --force
    milosum.py RUN.in

`--force` here means "keep the trajectory you already ran and add to it" — the
ensemble grows to 100 rather than starting over. A single trajectory is member
001 of the same ensemble, so your test run and your production run are the same
code path, and the test is not wasted.

Rough cost: 100 trajectories at 8 cpus each, with a few running at a time, is
overnight rather than an afternoon.

## About the submission script

You never have to write one, but it is worth knowing what is being submitted on
your behalf.

`runmilo.py` writes `<base>_milo.sh` next to your input and submits it as a
**job array**: one job with N members, one trajectory per member. Every member
runs the same input file — Milo draws its own random seed at run time and
records it, which is what makes them independent trajectories instead of a
hundred copies of one.

To see the script without submitting anything:

    runmilo.py RUN.in --traj 100 --dry-run

That prints the whole thing to your screen and submits nothing. The script sets
up Gaussian and python through the cluster's module system, copies your input to
node-local scratch, runs the trajectory there, copies the results back into
`results/`, and writes a header and footer into the joblog recording the host,
job id, scratch path, seed and exit code. If a member fails, its working
directory is preserved under `results.failed/` instead of being cleaned up.

If you prefer to submit by hand, or want to edit the script first, you can:

    runmilo.py RUN.in --traj 100 --force    # writes it, submits it
    qsub RUN_milo.sh                        # what runmilo.py just did for you

Useful flags, all of which have sensible defaults:

| flag | means |
|---|---|
| `--traj N` | how many trajectories |
| `-p` / `--cpus` | cpus per trajectory (8 is the standing choice) |
| `-m` / `--mem` | GB given to Gaussian; the scheduler is asked for a little more |
| `-t` | walltime; accepts `24`, `24h`, `90m` or `HH:MM:SS` |
| `--array-limit K` | at most K members running at once |
| `--dry-run` | print the script, submit nothing |
| `--site` | force a cluster preset instead of auto-detecting |

## When something goes wrong

| what you see | what it means |
|---|---|
| `command not found: runmilo.py` | `PATH` line missing or shell not reloaded — step 5 |
| `--check` fails on the `gaussian` group | you are not in it yet; jobs will fail until you are |
| `ERROR: no Milo found at ...` | Milo is somewhere non-default: `export MILO_HOME=<path>` |
| job disappears in seconds, joblog mentions memory | asked for more memory than your `-l` line allows; raise `-m` |
| `SKIP: ... already has results` | a finished trajectory is being protected; `--rerun` replaces it deliberately |
| `REFUSING` from `milosum.py` | too few members finished to quote a ratio honestly; the inventory still prints |

The last two are not bugs. This pipeline will not overwrite a good trajectory,
and it will not quote a branching ratio over an ensemble that mostly did not
finish.

## On a Slurm cluster instead

Everything above is identical except:

- the check looks for `sbatch` rather than `qsub`
- `qstat -u $USER` becomes `squeue -u $USER`
- `qsub script.sh` becomes `sbatch script.sh`
- if your cluster bills to an allocation, set `export MILO_ACCOUNT=<account>`
  (or pass `--account`) so jobs are charged to the right one

`runmilo.py` works out which scheduler it is on by itself and writes the right
kind of script; `--site` overrides it if you need to. Per-machine notes are in
`clusters/`.

## Uninstalling

Nothing is installed system-wide, so removing it is removing files:

    rm -f ~/Scripts/{runmilo.py,milosum.py,prepmilo.py,plot_traj.py}
    rm -f ~/Scripts/{test_runmilo.sh,test_milosum.sh,install_milo.sh}
    rm -rf ~/Programs/milo-1.0.3

and delete the `PATH` line from `~/.bashrc` if nothing else uses `~/Scripts`.
Your results are untouched by all of that — they live wherever you submitted
from.
