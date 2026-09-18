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

You land on a *login node*: the machine you get when you log in, meant for
editing files, small commands and submitting work. Anything that actually
calculates goes to the queue instead. Nothing in this install calculates, so all
of it is fine to run here.

**Stay logged in and type the commands at the prompt.** Running them the other
way — `ssh hoffman2 'some command'` from your laptop, one command at a time —
gives you a stripped-down shell each time, where `module load gaussian` fails
for reasons that have nothing to do with your account. If step 3 reports a
Gaussian problem, this is the first thing to check.

## Step 2 — get the code

    git clone https://github.com/avrubio20/milo-pipeline.git
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

On a fresh account, expect `FAIL` on the four tools, on Milo, and on both test
suites — none of that exists yet, and step 4 is what creates it.

What you are reading this output for is two lines: the `gaussian` group and
`g16`.

- **Group line fails.** You are not in the `gaussian` group yet. Everything else
  will install fine and then your first job will fail, so sort this out now.
- **Group line passes but `g16` fails.** Nine times out of ten this is the shell,
  not your account — see the note in step 1. Log in properly, run `--check`
  again, and only chase it further if it still fails.

## Step 4 — install, wherever you want it

    ./install_milo.sh --prefix ~/milo --add-path

`--prefix` is the one decision here: everything goes under that one directory,
and you can put it anywhere you can write.

1. Downloads Milo 1.0.3 and unpacks it into `~/milo/opt/milo-1.0.3`.
2. Copies the four tools (`runmilo.py`, `milosum.py`, `prepmilo.py`,
   `plot_traj.py`) and the two test suites into `~/milo/bin`.
3. Writes `~/.milo.conf`, recording where those went, which scheduler this
   machine uses, and the lines that make Gaussian runnable inside a job. The
   tools read that file, so you never have to tell them any of it again.
4. Adds a line to your `~/.bashrc` putting `~/milo/bin` on your `PATH`, so you
   can type `runmilo.py` from any folder instead of a full path.
5. Prints the commands to run next.

If you want the pieces somewhere else — Milo on a project allocation, the tools
in a `bin` directory you already have — override them individually:

    ./install_milo.sh --bindir ~/bin --milo-dir /u/project/mygroup/milo-1.0.3

`./install_milo.sh --help` lists all of them, and `--dry-run` shows you what
any combination would do without writing anything.

Two more, for cases that come up on shared machines:

- `--tarball FILE` installs Milo from a tarball you already have, for a node
  with no way out to GitHub. Download the release anywhere and hand it over.
- `--shared` makes the install group-readable, for one person installing on
  behalf of a lab. See the section below.

If your login shell is tcsh rather than bash, `--add-path` writes a `setenv`
line to `~/.cshrc` instead. It follows `$SHELL`.

Changed your mind later? Re-run it with different paths, or edit `~/.milo.conf`
directly — the tools read it every run. Re-running keeps what you set before
and only changes what you ask for; a flag always beats what is recorded.

These are the keys. The installer fills in the first six; the rest are yours to
add if you want them:

| key | means |
|---|---|
| `bindir` | where the four tools are |
| `milo_home` | where Milo itself is |
| `scratch` | fast temporary space a job should use |
| `scheduler` | `uge` or `slurm` |
| `account` | account to bill, if your cluster needs one |
| `g16_setup` | the shell lines that make `g16` runnable in a job |
| `python` | a specific interpreter for jobs, instead of `python3` |
| `plot_python` | an interpreter that has `ase` and `matplotlib`, for the plots |
| `array_limit` | most trajectories to run at once, if nothing else throttles you |
| `uge_resources` | UGE node-pool policy, default `arch=intel*` |
| `uge_pe` | UGE parallel environment, default `shared*` (sites also use `smp`, `openmp`) |
| `uge_project` | UGE project to bill, if your site wants `-P` |

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
suites, which the check runs for you.

The suites take about two seconds on a quiet machine, but a shared login node
with a busy filesystem can stretch that to a few minutes. Let it finish; it has
not hung.

If `runmilo.py` still comes back "not on PATH", the `PATH` line did not take.
Check it is really in `~/.bashrc` (`tail ~/.bashrc`), then open a fresh login.

## Installing once for a whole group

One person installs somewhere everybody can read, and everybody else does
nothing:

    ./install_milo.sh --prefix /u/project/mygroup/milo --shared --add-path

The tools land in `PREFIX/bin` and a copy of the config in `PREFIX/etc`. Anyone
with `PREFIX/bin` on their `PATH` picks up that config automatically — they do
not need their own, and they do not need write access to any of it. If someone
wants different settings, their own `~/.milo.conf` takes precedence, and
`MILO_CONF` beats both.

## Step 6 — one real trajectory, on the included example

    ./install_milo.sh --example
    cd milo_example
    runmilo.py DA_example.in --traj 1

`--example` re-runs the ordinary install (harmless — it reports everything is
already current) and then writes `milo_example/DA_example.in`: a 16-atom
Diels-Alder transition state, 50 steps, at 8 cpus and 12 GB. It is small on purpose — about ten
minutes of compute — and it carries the bond pairs the summary needs written
into it, so neither command below needs any options.

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

`freq/TS.out` is a stand-in for wherever your own Gaussian output actually is —
there is no such file in this repository, and nothing creates one for you. If
you do not have one yet, stop after step 6; the example already proved the
install works.

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

If you prefer to submit by hand, or want to edit the script first, use
`--no-submit` — it writes the script and stops:

    runmilo.py RUN.in --traj 100 --no-submit    # writes RUN_milo.sh, submits nothing
    qsub RUN_milo.sh                            # what runmilo.py would have done

Leave off `--no-submit` and it writes *and* submits, so do not do both.

Useful flags, all of which have sensible defaults:

| flag | means |
|---|---|
| `--traj N` | how many trajectories |
| `-p` / `--cpus` | cpus per trajectory (8 is the standing choice) |
| `-m` / `--mem` | GB given to Gaussian; the scheduler is asked for a little more |
| `-t` | walltime; accepts `24`, `24h`, `90m` or `HH:MM:SS`. Default 24 h — past that, UGE needs `highp`, which only runs on nodes your group owns |
| `--array-limit K` | at most K members running at once |
| `--no-submit` | write the script, submit nothing |
| `--dry-run` | print the script; write nothing, submit nothing |
| `--site` | force a cluster preset instead of auto-detecting |

## Words used above

You can install everything without these, but they turn up in every cluster
document you will read after this one.

| word | means |
|---|---|
| login node | the machine you land on when you ssh in; for editing and submitting, not computing |
| scheduler | the program that decides whose job runs where and when — UGE here, Slurm elsewhere |
| the queue | jobs waiting for the scheduler to give them a machine |
| job array | one submission that runs N near-identical jobs, here one trajectory each |
| module | the cluster's way of switching software on: `module load gaussian` puts Gaussian in reach |
| PATH | the list of folders your shell searches for a command, so you can type `runmilo.py` from anywhere |
| unix group | a named set of users; the `gaussian` one is who is allowed to run Gaussian |
| walltime | how long you are asking to be allowed to run before the scheduler stops you |
| allocation / account | the pot of compute time a job is billed to (Hoffman2 does not need one here) |
| scratch | fast temporary disk on the machine doing the work; wiped when the job ends |
| flag / option | the `--something` parts of a command, e.g. `--traj 100` |
| ensemble | all the trajectories of one run, treated as one statistical sample |
| branching ratio | what fraction of trajectories ended as product rather than reactant |

## Reading `--check`, line by line

Every line comes back `ok`, `note` or `FAIL`. A `note` is information, not a
problem. Here is what each `FAIL` means and what to do about it.

**`no config yet; install first`** — a `note`, and normal before you have
installed. It becomes `ok config: <path>` afterwards. If it still says this
after installing, the installer wrote its config somewhere else: pass the same
`--config` to both, or set `MILO_CONF`.

**`no qsub found -- are you on a login node?`** — `qsub` is how anything gets
submitted here. Almost always you are on the wrong kind of machine: a compute
node, or a shell that is not a real login. Log in again with `ssh` and try at
the prompt.

**`you are not in the 'gaussian' group, which is usually why`** — Gaussian is
licensed per group. Ask IDRE user support to add you, with your PI copied in to
confirm you are covered by their licence. This one you cannot work around, and
nothing will run until it is sorted.

**`g16 is not reachable after the setup lines in <config>`** — three causes,
in order of likelihood:

1. *The shell.* The gaussian module needs `$SCRATCH`, which only a login shell
   sets, so this fails under `ssh host "command"` or inside a script. The check
   prints this hint itself. Log in and run it at the prompt.
2. *The group*, above — the check says so on its own line.
3. *The setup lines are wrong for this machine.* Look at `g16_setup` in your
   config. Run those lines by hand; whatever error you get is the real one.

**`<tool> not on PATH (add <bindir> to it)`** — expected before installing, and
after installing means the `PATH` line has not taken. Either you have not run
`source ~/.bashrc`, or `--add-path` wrote to a file your shell does not read.
Check with `tail ~/.bashrc` (or `~/.cshrc` under tcsh), then open a fresh login.
If it works when you are logged in but not through `ssh host "command"`, that is
expected: most `.bashrc` files stop early for non-interactive shells.

**`no Milo at <dir> (run this script without --check first)`** — expected
before installing. Afterwards it means Milo is not where the config says. Check
`milo_home` in your config against what is actually on disk; the installer
puts it in `PREFIX/opt/milo-1.0.3`.

**`test_runmilo.sh: no Milo to borrow setup_backward.py from`** — the suite
needs a real Milo for one of its checks. Install first, or `export MILO_HOME`.
The failure lists every place it looked.

**`test_runmilo.sh: fresh run exited 1`** or another assertion — the generated
job script did not behave. Run the suite directly to see the whole output
rather than its last line:

    bash <bindir>/test_runmilo.sh

The usual cause after an update is a stale copy: `--check` runs the *installed*
suites, not the ones in your clone. Re-run the installer with `--force` after
`git pull`.

**`<suite> not found; skipping`** — a `note`. The suites are missing from both
the install and the current directory, which only happens with a partial
install. Re-run the installer.

## When something goes wrong

| what you see | what it means |
|---|---|
| `command not found: runmilo.py` | `PATH` line missing or shell not reloaded — step 5. If it works when you are logged in but not via `ssh host 'command'`, that is expected: see step 1 |
| `--check` fails on `g16` but the group line passed | almost always the shell, not your account — step 1 |
| `--check` fails on the `gaussian` group | you are not in it yet; jobs will fail until you are |
| `Milo's location is not recorded` | no `~/.milo.conf` yet — run the installer, or `export MILO_HOME=<path>` |
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
- `--check` tells you less there. The Gaussian and python checks in step 3 know
  how Hoffman2 publishes those; on an unrecognised Slurm machine the check
  confirms `sbatch`, the tools and Milo, and leaves Gaussian to you. Make sure
  `g16` runs before you submit anything.

`runmilo.py` works out which scheduler it is on by itself and writes the right
kind of script; `--site` overrides it if you need to.

Each machine also has its own notes folder, worth a look once you are past the
install: `clusters/hoffman2/`, `clusters/expanse/`, `clusters/workstation/`.
They hold the measured timings, the local quirks, and a `deploy.sh` for pushing
updated tools up from a machine you develop on.

## Uninstalling

Nothing is installed system-wide, so removing it is removing files:

    rm -rf ~/milo                   # or whatever you gave --prefix
    rm -f ~/.milo.conf
    rm -rf ~/milo-pipeline          # the clone, if you want that gone too

and delete the `PATH` line from `~/.bashrc`. One prefix, one config file, one
line in `.bashrc` — that is the whole footprint.
Your results are untouched by all of that — they live wherever you submitted
from.
