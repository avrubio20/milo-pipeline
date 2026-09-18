#!/bin/bash
# install_milo.sh -- install the Milo direct-dynamics pipeline for one account.
#
#   ./install_milo.sh                        install with this host's defaults
#   ./install_milo.sh --prefix ~/software    install somewhere else
#   ./install_milo.sh --check                can this machine actually run it?
#   ./install_milo.sh --example              write a ready-to-run test input
#   ./install_milo.sh --dry-run              print what it would do, write nothing
#
# Paths (each defaults to the one above it, so --prefix is usually enough):
#
#   --prefix DIR      everything under here            [$HOME/milo]
#   --bindir DIR      the four tools                   [PREFIX/bin]
#   --milo-dir DIR    Milo itself                      [PREFIX/opt/milo-1.0.3]
#   --scratch DIR     fast temporary space for jobs    [detected]
#   --account NAME    scheduler account to bill        [none]
#   --config FILE     where the choices are recorded   [$HOME/.milo.conf]
#   --add-path        put bindir on your PATH via ~/.bashrc
#   --force           replace installed files that differ from these
#
# The choices land in the config file, and the tools read them from there, so
# nothing has to be told twice. Re-running is safe and never submits a job.
set -uo pipefail

MILO_URL="https://github.com/DanielEss-lab/milo/archive/refs/tags/1.0.3.tar.gz"
MILO_VERSION="milo-1.0.3"
TOOLS=(runmilo.py milosum.py prepmilo.py plot_traj.py)
SUITES=(test_runmilo.sh test_milosum.sh)
SRC="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"

# Host knowledge lives here and nowhere else: how to reach Gaussian and python,
# and which temporary directory the scheduler gives a job. Everything below is
# written into the config file, so a machine this does not recognise is a
# matter of passing --scratch and editing two lines, not of patching code.
detect_host() {
    if [[ -n "${SGE_ROOT:-}" || -d /u/local/Modules ]]; then
        HOST=hoffman2
        SCHEDULER=uge
        DEF_SCRATCH='${TMPDIR:-$SCRATCH}'
        G16_SETUP='. /u/local/Modules/default/init/modules.sh
module load gaussian
module load python/3.9.6'
    elif command -v sbatch >/dev/null; then
        HOST=slurm
        SCHEDULER=slurm
        DEF_SCRATCH='${SLURM_TMPDIR:-/tmp}'
        G16_SETUP='# Make g16 runnable here, e.g. module load gaussian'
    else
        HOST=unknown
        SCHEDULER=slurm
        DEF_SCRATCH='/tmp'
        G16_SETUP='# Make g16 runnable here, e.g. module load gaussian'
    fi
}
detect_host

PREFIX="$HOME/milo"; BINDIR=""; MILO_DIR=""; SCRATCH=""; ACCOUNT=""
CONFIG="$HOME/.milo.conf"
DRY=0; FORCE=0; CHECK=0; ADDPATH=0; EXAMPLE=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --prefix)   PREFIX="$2";   shift 2;;
        --bindir)   BINDIR="$2";   shift 2;;
        --milo-dir) MILO_DIR="$2"; shift 2;;
        --scratch)  SCRATCH="$2";  shift 2;;
        --account)  ACCOUNT="$2";  shift 2;;
        --config)   CONFIG="$2";   shift 2;;
        --check)    CHECK=1;    shift;;
        --example)  EXAMPLE=1;  shift;;
        --add-path) ADDPATH=1;  shift;;
        --dry-run)  DRY=1;      shift;;
        --force)    FORCE=1;    shift;;
        -h|--help)  sed -n '2,22p' "$0"; exit 0;;
        *) echo "ERROR: unknown option $1 (try --help)" >&2; exit 1;;
    esac
done

expand() { echo "${1/#\~/$HOME}"; }
PREFIX="$(expand "$PREFIX")"
BINDIR="$(expand "${BINDIR:-$PREFIX/bin}")"
MILO_DIR="$(expand "${MILO_DIR:-$PREFIX/opt/$MILO_VERSION}")"
CONFIG="$(expand "$CONFIG")"
SCRATCH="${SCRATCH:-$DEF_SCRATCH}"

run() { if [[ $DRY -eq 1 ]]; then echo "  would: $*"; else "$@"; fi; }
ok()   { echo "  ok    $*"; }
bad()  { echo "  FAIL  $*"; FAILED=1; }
note() { echo "  note  $*"; }

# An installed config wins over the defaults above, so --check and a second
# --example look at the installation that exists rather than the one that would
# exist. Explicit flags still win over both: they are re-parsed after this.
if [[ -f "$CONFIG" ]]; then
    while IFS='=' read -r key value; do
        case "${key// /}" in
            bindir)    BINDIR="${value# }";;
            milo_home) MILO_DIR="${value# }";;
            scheduler) SCHEDULER="${value// /}";;
        esac
    done < "$CONFIG"
    # g16_setup spans several lines, its continuations indented, so --check
    # tests the setup you actually installed rather than the detected guess.
    installed_g16=$(awk '/^g16_setup *=/ {sub(/^g16_setup *= */, ""); print; got=1; next}
                         got && /^[[:space:]]/ {sub(/^[[:space:]]+/, ""); print; next}
                         got {exit}' "$CONFIG")
    [[ -n "$installed_g16" ]] && G16_SETUP="$installed_g16"
fi

if [[ $CHECK -eq 1 ]]; then
    echo "Environment check ($HOST)"
    FAILED=0
    [[ -f "$CONFIG" ]] && ok "config: $CONFIG" || note "no config yet; install first"

    if [[ "$SCHEDULER" == uge ]]; then
        # qsub is off PATH in a non-interactive shell, so look where UGE puts it.
        qsub_path="$(command -v qsub 2>/dev/null)"
        for c in /u/systems/UGE*/bin/lx-amd64/qsub /u/local/bin/qsub; do
            [[ -n "$qsub_path" ]] && break
            [[ -x "$c" ]] && qsub_path="$c"
        done
        [[ -n "$qsub_path" ]] && ok "qsub: $qsub_path" \
            || bad "no qsub found -- are you on a login node?"
    else
        command -v sbatch >/dev/null && ok "sbatch: $(command -v sbatch)" \
            || note "no sbatch on PATH; submitting will not work from here"
    fi

    if [[ "$HOST" == hoffman2 ]]; then
        groups 2>/dev/null | tr ' ' '\n' | grep -qx gaussian \
            && ok "you are in the 'gaussian' group" \
            || bad "you are NOT in the 'gaussian' group; Gaussian will not run"
    fi

    if (eval "$G16_SETUP" >/dev/null 2>&1; command -v g16 >/dev/null); then
        ok "g16 is reachable"
    else
        bad "g16 is not reachable after the setup lines in $CONFIG"
        echo "        If you are in the gaussian group, this is usually the shell:"
        echo "        the gaussian module needs \$SCRATCH, which only a login shell"
        echo "        sets. Log in with ssh and run this at the prompt, not through"
        echo "        'ssh host \"...\"' or a script."
    fi

    for tool in "${TOOLS[@]}"; do
        command -v "$tool" >/dev/null && ok "$tool on PATH" \
            || bad "$tool not on PATH (add $BINDIR to it)"
    done
    [[ -f "$MILO_DIR/milo_1_0_3/__main__.py" ]] && ok "Milo at $MILO_DIR" \
        || bad "no Milo at $MILO_DIR (run this script without --check first)"

    for suite in "${SUITES[@]}"; do
        path="$BINDIR/$suite"; [[ -f "$path" ]] || path="$SRC/$suite"
        if [[ -f "$path" ]]; then
            echo "  ...   running $suite (seconds here, minutes on a busy login node)"
            result=$(bash "$path" 2>&1 | tail -1)
            [[ "$result" == PASS* ]] && ok "$suite: $result" || bad "$suite: $result"
        else
            note "$suite not found; skipping"
        fi
    done

    echo
    [[ $FAILED -eq 0 ]] && echo "All good. Nothing was submitted." \
                        || echo "Fix the FAIL lines above before running anything."
    exit $FAILED
fi

echo "Milo pipeline install"
echo "  host:     $HOST ($SCHEDULER)"
echo "  tools:    $BINDIR"
echo "  Milo:     $MILO_DIR"
echo "  config:   $CONFIG"
[[ $DRY -eq 1 ]] && echo "  (dry run -- nothing will be written)"
echo

if [[ -f "$MILO_DIR/milo_1_0_3/__main__.py" ]]; then
    echo "Milo: already at $MILO_DIR"
elif [[ $DRY -eq 1 ]]; then
    echo "  would: download $MILO_URL into $MILO_DIR"
else
    echo "Milo: downloading into $MILO_DIR"
    mkdir -p "$MILO_DIR" || exit 1
    tarball="$(mktemp)"
    if command -v curl >/dev/null; then
        curl -fsSL "$MILO_URL" -o "$tarball"
    elif command -v wget >/dev/null; then
        wget -q "$MILO_URL" -O "$tarball"
    else
        echo "ERROR: neither curl nor wget; fetch $MILO_URL by hand" >&2; exit 1
    fi || { echo "ERROR: could not download $MILO_URL" >&2; exit 1; }
    # The tarball has its own top-level directory; --strip-components drops it
    # so MILO_DIR holds milo_1_0_3/ directly, whatever the release is called.
    tar -xzf "$tarball" --strip-components=1 -C "$MILO_DIR" \
        || { echo "ERROR: could not unpack $tarball" >&2; exit 1; }
    rm -f "$tarball"
    [[ -f "$MILO_DIR/milo_1_0_3/__main__.py" ]] \
        || { echo "ERROR: $MILO_DIR is not a Milo install" >&2; exit 1; }
fi

echo "Tools: $BINDIR"
run mkdir -p "$BINDIR"
for f in "${TOOLS[@]}" "${SUITES[@]}"; do
    [[ -f "$SRC/$f" ]] || { echo "  ERROR: $SRC/$f is missing" >&2; exit 1; }
    if [[ -e "$BINDIR/$f" && $FORCE -eq 0 ]] && ! cmp -s "$SRC/$f" "$BINDIR/$f"; then
        echo "  $f DIFFERS from the copy here -- --force to replace"
        continue
    fi
    run cp "$SRC/$f" "$BINDIR/$f"
    run chmod +x "$BINDIR/$f"
    echo "  $f"
done

echo "Config: $CONFIG"
if [[ $DRY -eq 1 ]]; then
    echo "  would: record bindir, milo_home, scratch, scheduler, g16 setup"
else
    cat > "$CONFIG" <<CONF
# Milo pipeline. Written by install_milo.sh on $(date +%F).
# Re-run it to change these, or edit them here -- the tools read this file.
bindir    = $BINDIR
milo_home = $MILO_DIR
scratch   = $SCRATCH
scheduler = $SCHEDULER
account   = $ACCOUNT

# Shell lines that make g16 (and python) runnable inside a job.
g16_setup = $(echo "$G16_SETUP" | sed '2,$s/^/            /')
CONF
    echo "  recorded; MILO_CONF overrides the location"
fi

if [[ $EXAMPLE -eq 1 ]]; then
    echo "Example: ./milo_example"
    run mkdir -p milo_example
    run cp "$SRC/examples/DA_example.in" milo_example/
    echo "  DA_example.in (16-atom Diels-Alder, 50 steps, 8 cpus / 12 GB)"
fi

PATH_LINE="export PATH=\"\$PATH:$BINDIR\""
echo
if [[ ":$PATH:" == *":$BINDIR:"* ]]; then
    echo "PATH: $BINDIR is already on it."
elif [[ $ADDPATH -eq 1 ]]; then
    if grep -qsF "$PATH_LINE" "$HOME/.bashrc"; then
        echo "~/.bashrc already has: $PATH_LINE"
    else
        run bash -c "printf '\n# Milo pipeline\n%s\n' \"\$1\" >> '$HOME/.bashrc'" _ "$PATH_LINE"
        echo "~/.bashrc += $PATH_LINE"
    fi
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
    echo "    $PATH_LINE"
fi

cat <<NEXT

Next, from this directory -- install_milo.sh is not copied onto your PATH:
    ./install_milo.sh --check        verifies the environment, runs the tests
    ./install_milo.sh --example      writes ./milo_example/
    cd milo_example
    runmilo.py DA_example.in --traj 1     one trajectory
    milosum.py DA_example.in              what happened
Then your own system, from a Gaussian freq=hpmodes output:
    prepmilo.py -i freq/TS.out -o RUN --fs 200 -p 8 -m 12
    runmilo.py RUN.in --traj 1
    runmilo.py RUN.in --traj 100 --force
NEXT
