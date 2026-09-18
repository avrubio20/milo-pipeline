# Expanse (SDSC)

    ssh <your-user>@login.expanse.sdsc.edu

**Scheduler: Slurm.** `runmilo.py` detects it through `ClusterName=expanse`;
`--site expanse` forces it. Partition `shared`; set your allocation with
`export MILO_ACCOUNT=<your-account>` (or pass `--account`).

## Paths

| what | where |
|---|---|
| Milo | `~/Programs/milo` |
| scripts | `~/bin` (what `install_milo.sh` uses here) |
| scratch | `/scratch/$USER/job_$SLURM_JOB_ID` |
| test runs | wherever you submit from |

## Gotchas that cost time here

- **`conda activate base` first.** The system python is 3.6.8, too old; base is
  3.8.8. The generated job script is fine either way, but `runmilo.py` and
  `milosum.py` need the newer one to run at all.
- **There is no `bsd/g16.profile`.** `module load cpu/0.15.4 gaussian/16.C.01`
  sets `PATH`/`GAUSS_EXEDIR`/`G16_BASIS` itself. Do not port the Bridges-2
  `source` line.
- **`--mem` is enforced** (`TaskPlugin=task/cgroup`), unlike the workstation
  where it is advisory. Under-declaring kills the member.
- **Billing is `max(cores, mem/2011MB)`**, so keep `--mem` at or under ~2 GB per
  core or you pay for cores you did not use. `-p 8 -m 12` (16 G requested) bills
  8.15; `-m 16` (20 G) bills 10.2 for the same 8 cores.
- **No ase/matplotlib**, so plots are skipped with a NOTE. rsync results back
  and plot on the workstation.
- `MaxArraySize=1000`; the `shared` QOS allows 8192 cores per user.

## Measured

16-atom Diels-Alder, 50 steps, 8 cpus / 12 GB: ~6.5 min per trajectory.
100 members is roughly 90 SU.

## Deploy from the workstation

    clusters/expanse/deploy.sh

Set `MILO_EXPANSE_HOST=<user>@login.expanse.sdsc.edu` first.
