#!/bin/bash
# Push the shared tools to Expanse and prove they still pass there.
set -uo pipefail
SRC="$(cd "$(dirname "$(readlink -f "$0")")/../.." && pwd)"
# Your login, e.g. MILO_EXPANSE_HOST=jsmith@login.expanse.sdsc.edu
HOST="${MILO_EXPANSE_HOST:-$USER@login.expanse.sdsc.edu}"
SSH=(ssh ${MILO_SSH_OPTS:-})
DEST="${1:-bin}"
FILES=(runmilo.py milosum.py prepmilo.py plot_traj.py
       test_runmilo.sh test_milosum.sh install_milo.sh)

echo "expanse:$DEST <- $SRC"
"${SSH[@]}" "$HOST" "mkdir -p '$DEST/examples'" || exit 1
rsync -e "${SSH[*]}" -q "${FILES[@]/#/$SRC/}" "$HOST:$DEST/" || exit 1
rsync -e "${SSH[*]}" -q "$SRC/examples/DA_example.in" "$HOST:$DEST/examples/" || exit 1
"${SSH[@]}" "$HOST" "chmod +x '$DEST'/*.py '$DEST'/*.sh"
echo "--- suites on Expanse (conda base for python 3.8) ---"
"${SSH[@]}" "$HOST" "bash -lc 'source ~/.bashrc >/dev/null 2>&1; conda activate base >/dev/null 2>&1; \
  bash ~/$DEST/test_runmilo.sh 2>&1 | tail -1; bash ~/$DEST/test_milosum.sh 2>&1 | tail -1'"
