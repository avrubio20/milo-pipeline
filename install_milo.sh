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
#   --tarball FILE    install Milo from a local tarball instead of downloading
#   --shared          make the install readable and usable by your unix group
#   --add-path        put bindir on your PATH (~/.bashrc, or ~/.cshrc under csh)
#   --force           replace installed files that differ from these
#
# Your choices are saved to the config file and read back by the tools.
# Re-running is safe. Nothing here ever submits a job.
set -uo pipefail

MILO_URL="https://github.com/DanielEss-lab/milo/archive/refs/tags/1.0.3.tar.gz"
MILO_VERSION="milo-1.0.3"
TOOLS=(runmilo.py milosum.py prepmilo.py plot_traj.py)
SUITES=(test_runmilo.sh test_milosum.sh)
SRC="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"

# Per-machine defaults. These get written into the config file, so an
# unrecognised machine means editing the config, not this script.
detect_host() {
    if [[ -n "${SGE_ROOT:-}" || -d /u/local/Modules ]]; then
        HOST=hoffman2
        SCHEDULER=uge
        DEF_SCRATCH='${TMPDIR:-${SCRATCH:-/tmp}}'
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

DEFAULT_PREFIX="$HOME/milo"
PREFIX=""; BINDIR=""; MILO_DIR=""; SCRATCH=""; ACCOUNT=""
CONFIG="$HOME/.milo.conf"
TARBALL=""; SHARED=0
DRY=0; FORCE=0; CHECK=0; ADDPATH=0; EXAMPLE=0

# Must not run in a subshell, or the exit is lost.
argval() {
    [[ -n "${2:-}" && "${2:-}" != --* ]] && return 0
    echo "ERROR: $1 needs a value" >&2
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --prefix)   argval "$1" "${2:-}"; PREFIX="$2";   shift 2;;
        --bindir)   argval "$1" "${2:-}"; BINDIR="$2";   shift 2;;
        --milo-dir) argval "$1" "${2:-}"; MILO_DIR="$2"; shift 2;;
        --scratch)  argval "$1" "${2:-}"; SCRATCH="$2";  shift 2;;
        --account)  argval "$1" "${2:-}"; ACCOUNT="$2";  shift 2;;
        --config)   argval "$1" "${2:-}"; CONFIG="$2";   shift 2;;
        --tarball)  argval "$1" "${2:-}"; TARBALL="$2"; shift 2;;
        --shared)   SHARED=1;   shift;;
        --check)    CHECK=1;    shift;;
        --example)  EXAMPLE=1;  shift;;
        --add-path) ADDPATH=1;  shift;;
        --dry-run)  DRY=1;      shift;;
        --force)    FORCE=1;    shift;;
        -h|--help)  sed -n '2,22p' "$0"; exit 0;;
        *) echo "ERROR: unknown option $1 (try --help)" >&2; exit 1;;
    esac
done

if [[ $CHECK -eq 1 ]] \
   && [[ $EXAMPLE -eq 1 || $ADDPATH -eq 1 || $SHARED -eq 1 || $DRY -eq 1 || $FORCE -eq 1 ]]; then
    echo "ERROR: --check only reports. Run it on its own, then install." >&2
    exit 1
fi

expand() { echo "${1/#\~/$HOME}"; }
CONFIG="$(expand "$CONFIG")"

run() {
    if [[ $DRY -eq 1 ]]; then echo "  would: $(printf '%q ' "$@")"
    else "$@"; fi
}
ok()   { echo "  ok    $*"; PASSED=$((PASSED + 1)); TOTAL=$((TOTAL + 1)); }
bad()  { echo "  FAIL  $*"; FAILED=1;  TOTAL=$((TOTAL + 1)); }
note() { echo "  note  $*"; }

# An existing config fills in whatever you did not pass this time.
cfg() { [[ -f "$CONFIG" ]] && sed -n "s/^ *$1 *= *//p" "$CONFIG" | head -1; }
CFG_BINDIR="$(cfg bindir)"; CFG_MILO="$(cfg milo_home)"
CFG_SCRATCH="$(cfg scratch)"; CFG_ACCOUNT="$(cfg account)"
CFG_SCHEDULER="$(cfg scheduler)"
# g16_setup runs to several indented lines, ending at a blank one.
CFG_G16=$([[ -f "$CONFIG" ]] && awk '
    /^g16_setup *=/ { sub(/^g16_setup *= */, ""); print; found=1; next }
    found && /^[[:space:]]*$/ { exit }
    found && /^[[:space:]]/ { sub(/^[[:space:]]+/, ""); print; next }
    found { exit }' "$CONFIG")

# Order: --bindir/--milo-dir, then --prefix, then the config, then defaults.
[[ -n "$PREFIX" && -z "$BINDIR" ]]   && BINDIR="$(expand "$PREFIX")/bin"
[[ -n "$PREFIX" && -z "$MILO_DIR" ]] && MILO_DIR="$(expand "$PREFIX")/opt/$MILO_VERSION"
BINDIR="$(expand "${BINDIR:-${CFG_BINDIR:-$DEFAULT_PREFIX/bin}}")"
MILO_DIR="$(expand "${MILO_DIR:-${CFG_MILO:-$DEFAULT_PREFIX/opt/$MILO_VERSION}}")"
SCRATCH="${SCRATCH:-${CFG_SCRATCH:-$DEF_SCRATCH}}"
ACCOUNT="${ACCOUNT:-$CFG_ACCOUNT}"
# Detected wins, matching runmilo.py: one home directory can serve two
# clusters, and the machine you are on is the better authority.
[[ "$HOST" == unknown && -n "$CFG_SCHEDULER" ]] && SCHEDULER="$CFG_SCHEDULER"
[[ -n "$CFG_G16" ]] && G16_SETUP="$CFG_G16"

if [[ $CHECK -eq 1 ]]; then
    echo "Environment check ($HOST)"
    FAILED=0; NO_SUBMIT=0; PASSED=0; TOTAL=0
    [[ -f "$CONFIG" ]] && ok "config: $CONFIG" || note "no config yet; install first"

    if [[ "$SCHEDULER" == uge ]]; then
        # qsub is off PATH in a non-interactive shell.
        qsub_path="$(command -v qsub 2>/dev/null)"
        for c in /u/systems/UGE*/bin/lx-amd64/qsub /u/local/bin/qsub; do
            [[ -n "$qsub_path" ]] && break
            [[ -x "$c" ]] && qsub_path="$c"
        done
        [[ -n "$qsub_path" ]] && ok "qsub: $qsub_path" \
            || bad "no qsub found -- are you on a login node?"
    else
        if command -v sbatch >/dev/null; then
            ok "sbatch: $(command -v sbatch)"
        else
            NO_SUBMIT=1
            note "no sbatch on PATH; you can prepare jobs here but not submit"
        fi
    fi

    # g16 running is what matters; the group is only the usual reason it does
    # not. Some sites license it to a differently-named group.
    if (eval "$G16_SETUP" >/dev/null 2>&1; command -v g16 >/dev/null); then
        ok "g16 is reachable"
        groups 2>/dev/null | tr ' ' '\n' | grep -qx gaussian \
            || note "not in the 'gaussian' group, but g16 works -- your site"\
                    "may license it to another group"
    else
        groups 2>/dev/null | tr ' ' '\n' | grep -qx gaussian \
            || bad "you are not in the 'gaussian' group, which is usually why"
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
        if [[ -f "$BINDIR/$suite" && -f "$SRC/$suite" ]] \
           && ! cmp -s "$BINDIR/$suite" "$SRC/$suite"; then
            note "$suite here differs from the installed one; testing the"\
                 "installed copy. Re-run with --force to update it."
        fi
        if [[ -f "$path" ]]; then
            echo "  ...   running $suite (seconds here, minutes on a busy login node)"
            output=$(bash "$path" 2>&1); rc=$?
            result=$(tail -1 <<<"$output")
            [[ $rc -eq 0 && "$result" == PASS* ]] \
                && ok "$suite: $result" || bad "$suite: $result (exit $rc)"
        else
            bad "$suite not found in $BINDIR or $SRC -- reinstall"
        fi
    done

    echo
    if [[ $FAILED -ne 0 ]]; then
        echo "Passed $PASSED/$TOTAL checks. Fix the FAIL lines above."
    elif [[ $NO_SUBMIT -eq 1 ]]; then
        echo "Passed $PASSED/$TOTAL checks, but this machine has no scheduler"
        echo "to submit to."
    else
        echo "Passed $PASSED/$TOTAL checks."
    fi
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
    [[ -n "$TARBALL" ]] && echo "  would: unpack $TARBALL into $MILO_DIR" \
                        || echo "  would: download $MILO_URL into $MILO_DIR"
else
    if [[ -d "$MILO_DIR" ]] && [[ -n "$(ls -A "$MILO_DIR" 2>/dev/null)" ]] \
       && [[ $FORCE -eq 0 ]]; then
        echo "ERROR: $MILO_DIR is not empty and is not a Milo install." >&2
        echo "       Pick another --milo-dir, or --force to unpack into it." >&2
        exit 1
    fi
    created_dir=0
    [[ -d "$MILO_DIR" ]] || created_dir=1
    mkdir -p "$MILO_DIR" || { echo "ERROR: cannot create $MILO_DIR" >&2; exit 1; }
    # Whatever goes wrong below, do not leave debris behind.
    cleanup_milo() {
        [[ -z "${tarball:-}" || -n "$TARBALL" ]] || rm -f "$tarball"
        [[ $created_dir -eq 1 && ! -f "$MILO_DIR/milo_1_0_3/__main__.py" ]] \
            && rm -rf "$MILO_DIR"
        return 0
    }
    trap cleanup_milo EXIT
    if [[ -n "$TARBALL" ]]; then
        echo "Milo: unpacking $TARBALL into $MILO_DIR"
        tarball="$TARBALL"
        [[ -f "$tarball" ]] || { echo "ERROR: no such file: $tarball" >&2; exit 1; }
    else
        echo "Milo: downloading into $MILO_DIR"
        tarball="$(mktemp)"
        if command -v curl >/dev/null; then
            curl -fsSL "$MILO_URL" -o "$tarball"
        elif command -v wget >/dev/null; then
            wget -q "$MILO_URL" -O "$tarball"
        else
            echo "ERROR: neither curl nor wget available." >&2
            echo "       Download $MILO_URL elsewhere and pass --tarball FILE." >&2
            exit 1
        fi || { echo "ERROR: could not download $MILO_URL." >&2
                echo "       If this node has no way out, download it elsewhere" >&2
                echo "       and pass --tarball FILE." >&2; exit 1; }
    fi
    # --strip-components drops the tarball's own top directory.
    tar -xzf "$tarball" --strip-components=1 -C "$MILO_DIR" \
        || { echo "ERROR: could not unpack $tarball" >&2; exit 1; }
    [[ -f "$MILO_DIR/milo_1_0_3/__main__.py" && -d "$MILO_DIR/milo_1_0_3/tools" ]] \
        || { echo "ERROR: $MILO_DIR does not look like Milo after unpacking" >&2; exit 1; }
    cleanup_milo; trap - EXIT
fi

echo "Tools: $BINDIR"
run mkdir -p "$BINDIR" || { echo "ERROR: cannot create $BINDIR" >&2; exit 1; }
STALE=0
for f in "${TOOLS[@]}" "${SUITES[@]}"; do
    [[ -f "$SRC/$f" ]] || { echo "  ERROR: $SRC/$f is missing" >&2; exit 1; }
    if [[ -e "$BINDIR/$f" ]] && cmp -s "$SRC/$f" "$BINDIR/$f"; then
        echo "  $f (already current)"
        continue
    fi
    if [[ -e "$BINDIR/$f" && $FORCE -eq 0 ]]; then
        echo "  $f DIFFERS from the copy here -- --force to replace"
        STALE=1
        continue
    fi
    run cp "$SRC/$f" "$BINDIR/$f" || { echo "ERROR: cannot write $BINDIR/$f" >&2; exit 1; }
    run chmod +x "$BINDIR/$f" || exit 1
    echo "  $f"
done

echo "Config: $CONFIG"
if [[ $DRY -eq 1 ]]; then
    echo "  would: record bindir, milo_home, scratch, scheduler, g16 setup"
else
    mkdir -p "$(dirname "$CONFIG")" \
        || { echo "ERROR: cannot create $(dirname "$CONFIG")" >&2; exit 1; }
    [[ ! -e "$CONFIG" || -w "$CONFIG" ]] \
        || { echo "ERROR: $CONFIG is not yours to write" >&2; exit 1; }
    # Write aside, then move: never leave a half-written config.
    tmp_config="$CONFIG.$$"
    cat > "$tmp_config" <<CONF
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
    [[ -s "$tmp_config" ]] && mv "$tmp_config" "$CONFIG" \
        || { rm -f "$tmp_config"; echo "ERROR: could not write $CONFIG" >&2; exit 1; }
    echo "  recorded; MILO_CONF overrides the location"
    # A copy here lets anyone with PREFIX/bin on their PATH use this install.
    shared_dir="$(dirname "$BINDIR")/etc"
    if mkdir -p "$shared_dir" 2>/dev/null && cp "$CONFIG" "$shared_dir/milo.conf" 2>/dev/null; then
        echo "  copy at $shared_dir/milo.conf for anyone else using this install"
    fi
fi

if [[ $EXAMPLE -eq 1 ]]; then
    echo "Example: ./milo_example"
    [[ -f "$SRC/examples/DA_example.in" ]] \
        || { echo "ERROR: $SRC/examples/DA_example.in is missing" >&2; exit 1; }
    run mkdir -p milo_example || exit 1
    run cp "$SRC/examples/DA_example.in" milo_example/ \
        || { echo "ERROR: cannot write ./milo_example" >&2; exit 1; }
    echo "  DA_example.in (16-atom Diels-Alder, 50 steps, 8 cpus / 12 GB)"
fi

# bash and tcsh keep their PATH in different files.
case "${SHELL:-/bin/bash}" in
    *csh) RC="$HOME/.cshrc"; PATH_LINE="setenv PATH \"\${PATH}:$BINDIR\"";;
    *)    RC="$HOME/.bashrc"; PATH_LINE="export PATH=\"\$PATH:$BINDIR\"";;
esac
echo
if [[ ":${PATH:-}:" == *":$BINDIR:"* ]]; then
    echo "PATH: $BINDIR is already on it."
elif [[ $ADDPATH -eq 1 ]]; then
    if grep -qsF "$PATH_LINE" "$RC"; then
        echo "$RC already has: $PATH_LINE"
    else
        run bash -c "printf '\n# Milo pipeline\n%s\n' \"\$1\" >> '$RC'" _ "$PATH_LINE" \
            || { echo "ERROR: cannot write $RC; add this line yourself:" >&2
                 echo "    $PATH_LINE" >&2; exit 1; }
        echo "$RC += $PATH_LINE"
    fi
    echo "Run 'source $RC' or log back in."
    if grep -qsE '^\s*(\[\[ \$-|case \$-)' "$RC"; then
        echo
        echo "NOTE: your $RC returns early for non-interactive shells, and"
        echo "      the line above was appended after that point. It applies when"
        echo "      you are typing at a prompt -- which is how this is meant to be"
        echo "      used -- but not to 'ssh host \"command\"' or scripts."
    fi
else
    echo "Add to $RC (or re-run with --add-path):"
    echo "    $PATH_LINE"
fi

if [[ $SHARED -eq 1 ]]; then
    echo
    echo "Shared: making $BINDIR and $MILO_DIR readable by your group"
    run chmod -R g+rX "$BINDIR" "$MILO_DIR" \
        || { echo "ERROR: could not make the install group-readable" >&2; exit 1; }
    # setgid: files added later keep the group.
    run find "$BINDIR" "$MILO_DIR" -type d -exec chmod g+s {} + \
        || echo "  WARNING: could not set setgid; new files may land in the" \
                "wrong group" >&2
    # Group read is useless if the group cannot walk in from above. Test the
    # directory's own mode, not whether *you* can enter it.
    for d in "$(dirname "$BINDIR")" "$(dirname "$MILO_DIR")"; do
        perms="$(stat -c %A "$d" 2>/dev/null)"
        [[ "${perms:5:1}" == x ]] \
            || echo "  WARNING: $d ($perms) is not enterable by your group;" \
                    "they will not reach this install" >&2
    done
fi

if [[ $STALE -eq 1 ]]; then
    cat >&2 <<STALE_MSG

Some tools already installed differ from the ones here and were left alone, so
$BINDIR is now a mix of two versions. Re-run with --force to replace them.
STALE_MSG
    exit 1
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
