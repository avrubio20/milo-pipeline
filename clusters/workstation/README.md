# A plain Slurm workstation (`--site local`)

**Scheduler: Slurm**, `ClusterName=localcluster`, which `runmilo.py` maps to
`--site local`. 32 cores, RTX 5080, MPS usually on.

## Paths

| what | where |
|---|---|
| Milo | `~/Programs/milo` (a git clone of DanielEss-lab/milo) |
| these tools | this repo, symlinked into `~/bin` |
| scratch | `${SLURM_TMPDIR:-/tmp}` |
| test runs | wherever you submit from |

## Local-only behaviour

- **`--mem` is advisory here** (`TaskPlugin=task/none`), so nothing stops a
  100-member array from starting at once. `--array-limit` therefore defaults to
  `cores / cpus` and says what it chose. That is the only real throttle.
- g16 comes from `source /etc/g16setup`.
- ase + matplotlib are present, so plots are produced.

## Measured

16-atom Diels-Alder, 50 steps: 2c 338 s, 4c 200 s, 8c 172 s, 16c 148 s,
24c 191 s -- 24 cores is past the knee. The knee moves right with
basis-function count, not atom count. 8 is the standing production choice.

## Editing

If `~/bin/runmilo.py` is a symlink into this repo, edits land in the repo --
which is what you want, and what `install_milo.sh` does not do (it copies).
Pick one style per machine and stay with it.
