#!/bin/bash
# install_milo.sh -- put the Milo direct-dynamics pipeline on an account.
#
#   ./install_milo.sh                 # install for me, with this host's defaults
#   ./install_milo.sh --check         # is the environment actually able to run it?
#   ./install_milo.sh --example       # drop a ready-to-run test in ./milo_example
#   ./install_milo.sh --add-path      # append the PATH line to ~/.bashrc
#   ./install_milo.sh --dry-run       # print what it would do, write nothing
#
# Installs Milo itself (downloaded if absent) plus the wrapper scripts. Safe to
# re-run: nothing is overwritten without --force. Never submits a job.
set -uo pipefail

MILO_URL="https://github.com/DanielEss-lab/milo/archive/refs/tags/1.0.3.tar.gz"
MILO_DIRNAME="milo-1.0.3"
TOOLS=(runmilo.py milosum.py prepmilo.py plot_traj.py)
SUITES=(test_runmilo.sh test_milosum.sh)
SRC="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"

if [[ -n "${SGE_ROOT:-}" || -d /u/local/Modules ]]; then
    HOST_KIND="hoffman2"
    DEF_SCRIPTS="$HOME/Scripts"
else
    HOST_KIND="generic"
    DEF_SCRIPTS="$HOME/bin"
fi
DEF_PROGRAMS="$HOME/Programs"

PROGRAMS=""; SCRIPTS=""; DRY=0; FORCE=0; CHECK=0; ADDPATH=0; EXAMPLE=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --programs) PROGRAMS="$2"; shift 2;;
        --scripts)  SCRIPTS="$2";  shift 2;;
        --check)    CHECK=1; shift;;
        --example)  EXAMPLE=1; shift;;
        --add-path) ADDPATH=1; shift;;
        --dry-run)  DRY=1; shift;;
        --force)    FORCE=1; shift;;
        -h|--help)  sed -n '2,13p' "$0"; exit 0;;
        *) echo "ERROR: unknown option $1 (try --help)" >&2; exit 1;;
    esac
done

PROGRAMS="${PROGRAMS:-$DEF_PROGRAMS}"; SCRIPTS="${SCRIPTS:-$DEF_SCRIPTS}"
PROGRAMS="${PROGRAMS/#\~/$HOME}"; SCRIPTS="${SCRIPTS/#\~/$HOME}"
run() { if [[ $DRY -eq 1 ]]; then echo "  would: $*"; else "$@"; fi; }

ok(){ echo "  ok    $*"; }; bad(){ echo "  FAIL  $*"; FAILED=1; }; warn(){ echo "  note  $*"; }

# --------------------------------------------------------------- --check ----
if [[ $CHECK -eq 1 ]]; then
    echo "Environment check ($HOST_KIND)"
    FAILED=0
    if [[ "$HOST_KIND" == "hoffman2" ]]; then
        qs=""; for p in "$(command -v qsub 2>/dev/null)" \
            /u/systems/UGE*/bin/lx-amd64/qsub /u/local/bin/qsub; do
            [[ -x "${p:-}" ]] && qs="$p" && break
        done
        [[ -n "$qs" ]] && ok "qsub: $qs" || bad "no qsub found -- are you on a login node?"
        if groups 2>/dev/null | tr ' ' '\n' | grep -qx gaussian; then
            ok "you are in the 'gaussian' group"
        else
            bad "you are NOT in the 'gaussian' group; Gaussian will not run. Ask IDRE to add you."
        fi
        if . /u/local/Modules/default/init/modules.sh 2>/dev/null && \
           module load gaussian 2>/dev/null && command -v g16 >/dev/null; then
            ok "module load gaussian -> $(command -v g16)"
        else
            bad "'module load gaussian' did not give a working g16"
            echo "        If you are in the gaussian group, this is usually the shell:"
            echo "        the gaussian module needs \$SCRATCH, which only a login shell"
            echo "        sets. Log in with ssh and run this at the prompt, not through"
            echo "        'ssh host \"...\"' or a script."
        fi
        if (. /u/local/Modules/default/init/modules.sh 2>/dev/null && \
            module load python/3.9.6 2>/dev/null && python3 -V >/dev/null 2>&1); then
            ok "module load python/3.9.6"
        else
            bad "python/3.9.6 module missing -- the job scripts load it"
        fi
    else
        command -v sbatch >/dev/null && ok "sbatch: $(command -v sbatch)" || warn "no sbatch on PATH"
    fi
    for tool in "${TOOLS[@]}"; do
        if command -v "$tool" >/dev/null; then ok "$tool on PATH"
        else bad "$tool not on PATH (add $SCRIPTS to it)"; fi
    done
    MH="${MILO_HOME:-}"
    if [[ -z "$MH" ]]; then
        for c in "$PROGRAMS/$MILO_DIRNAME" "$HOME/Programs/$MILO_DIRNAME" \
                 "$HOME/Programs/milo"; do
            [[ -f "$c/milo_1_0_3/__main__.py" ]] && MH="$c" && break
        done
        MH="${MH:-$PROGRAMS/$MILO_DIRNAME}"
    fi
    [[ -f "$MH/milo_1_0_3/__main__.py" ]] && ok "Milo at $MH" \
        || bad "no Milo at $MH (run this script without --check first)"
    for suite in "${SUITES[@]}"; do
        # installed copy first, else the one sitting beside this script
        path=""
        for c in "$SCRIPTS/$suite" "$SRC/$suite"; do
            [[ -f "$c" ]] && path="$c" && break
        done
        if [[ -n "$path" ]]; then
            printf "  ...   running %s\n" "$suite"
            r=$(bash "$path" 2>&1 | tail -1)
            [[ "$r" == PASS* ]] && ok "$suite: $r" || bad "$suite: $r"
        else
            warn "$suite not found; skipping"
        fi
    done
    echo
    [[ ${FAILED:-0} -eq 0 ]] && echo "All good. Nothing was submitted." \
        || echo "Fix the FAIL lines above before running anything."
    exit ${FAILED:-0}
fi

# -------------------------------------------------------------- install ----
echo "Milo pipeline install"
echo "  host:     $HOST_KIND"
echo "  programs: $PROGRAMS"
echo "  scripts:  $SCRIPTS"
[[ $DRY -eq 1 ]] && echo "  (dry run -- nothing will be written)"
echo

MILO_HOME_PATH="$PROGRAMS/$MILO_DIRNAME"
if [[ -d "$MILO_HOME_PATH/milo_1_0_3" ]]; then
    echo "Milo: already at $MILO_HOME_PATH"
elif [[ -d "$PROGRAMS/milo/milo_1_0_3" ]]; then
    MILO_HOME_PATH="$PROGRAMS/milo"
    echo "Milo: already at $MILO_HOME_PATH"
else
    echo "Milo: installing into $PROGRAMS"
    run mkdir -p "$PROGRAMS"
    if [[ $DRY -eq 0 ]]; then
        tarball="$PROGRAMS/${MILO_DIRNAME}.tar.gz"
        if command -v curl >/dev/null; then curl -fsSL "$MILO_URL" -o "$tarball"
        elif command -v wget >/dev/null; then wget -q "$MILO_URL" -O "$tarball"
        else echo "ERROR: neither curl nor wget; fetch $MILO_URL by hand" >&2; exit 1; fi \
            || { echo "ERROR: could not download Milo from $MILO_URL" >&2; exit 1; }
        tar -xzf "$tarball" -C "$PROGRAMS" || { echo "ERROR: extract failed" >&2; exit 1; }
        [[ -d "$MILO_HOME_PATH" ]] || mv "$PROGRAMS"/milo-* "$MILO_HOME_PATH" 2>/dev/null
        rm -f "$tarball"
    fi
fi
[[ $DRY -eq 0 && ! -f "$MILO_HOME_PATH/milo_1_0_3/__main__.py" ]] && {
    echo "ERROR: $MILO_HOME_PATH is not a Milo install" >&2; exit 1; }

echo "Scripts: $SCRIPTS"
run mkdir -p "$SCRIPTS"
for f in "${TOOLS[@]}" "${SUITES[@]}"; do
    [[ -f "$SRC/$f" ]] || { echo "  ERROR: $SRC/$f missing" >&2; exit 1; }
    if [[ -e "$SCRIPTS/$f" && $FORCE -eq 0 ]] && ! cmp -s "$SRC/$f" "$SCRIPTS/$f"; then
        echo "  $f DIFFERS from the copy here -- --force to replace"; continue
    fi
    run cp "$SRC/$f" "$SCRIPTS/$f"; run chmod +x "$SCRIPTS/$f"; echo "  $f"
done

if [[ $EXAMPLE -eq 1 ]]; then
    echo "Example: ./milo_example"
    run mkdir -p milo_example
    run cp "$SRC/examples/DA_example.in" milo_example/
    echo "  DA_example.in (16-atom Diels-Alder, 50 steps, 8 cpus / 12 GB)"
fi

LINE="export PATH=\"\$PATH:$SCRIPTS\""
# MILO_HOME is always written, not only when the path is unusual: the site
# presets in runmilo.py name a directory per cluster, and an install that lands
# somewhere else -- ~/Programs/milo-1.0.3 where a preset says ~/Programs/milo --
# would otherwise fail inside the job rather than here.
MH_LINE="export MILO_HOME=\"$MILO_HOME_PATH\""

echo
if [[ ":$PATH:" == *":$SCRIPTS:"* && -z "$MH_LINE" ]]; then
    echo "PATH: $SCRIPTS is already on it. Nothing else to set."
elif [[ $ADDPATH -eq 1 ]]; then
    grep -qs '^# Milo pipeline$' "$HOME/.bashrc" \
        || run bash -c "printf '\n# Milo pipeline\n' >> '$HOME/.bashrc'"
    for line in "$LINE" "$MH_LINE"; do
        [[ -z "$line" ]] && continue
        # Already on PATH from some earlier line? Do not add a second one that
        # differs only in quoting.
        [[ "$line" == "$LINE" && ":$PATH:" == *":$SCRIPTS:"* ]] \
            && { echo "~/.bashrc: $SCRIPTS is already on your PATH, leaving it alone"; continue; }
        if grep -qsF "$line" "$HOME/.bashrc"; then
            echo "~/.bashrc already has: $line"
        else
            run bash -c "printf '%s\n' \"\$1\" >> '$HOME/.bashrc'" _ "$line"
            echo "~/.bashrc += $line"
        fi
    done
    echo "Run 'source ~/.bashrc' or log back in."
    if grep -qsE '^\s*(\[\[ \$-|case \$-)' "$HOME/.bashrc"; then
        echo
        echo "NOTE: your ~/.bashrc returns early for non-interactive shells, and"
        echo "      the line above was appended after that point. It applies when"
        echo "      you are typing at a prompt -- which is how this is meant to be"
        echo "      used -- but not to 'ssh host \"command\"' or scripts."
    fi
else
    echo "Add to ~/.bashrc (or re-run with --add-path):"
    [[ ":$PATH:" == *":$SCRIPTS:"* ]] || echo "    $LINE"
    [[ -n "$MH_LINE" ]] && echo "    $MH_LINE"
fi

cat <<NEXT

Next (from this directory -- install_milo.sh stays here, it is not copied
to your PATH like the four tools are):
    ./install_milo.sh --check        # verifies the environment and runs the tests
    ./install_milo.sh --example      # installs as usual, and writes ./milo_example/
    cd milo_example
    runmilo.py DA_example.in --traj 1     # one trajectory, ~10 min on Hoffman2
    milosum.py DA_example.in              # what happened
Then the real thing, from your own Gaussian freq=hpmodes output:
    prepmilo.py -i freq/TS.out -o RUN --fs 200 -p 8 -m 12
    runmilo.py RUN.in --traj 1
    runmilo.py RUN.in --traj 100 --force
NEXT
