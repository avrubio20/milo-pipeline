#!/bin/bash
# Push the shared tools to Hoffman2 and prove they still pass there.
set -uo pipefail
SRC="$(cd "$(dirname "$(readlink -f "$0")")/../.." && pwd)"
HOST="${MILO_HOFFMAN2_HOST:-hoffman2}"
DEST="${1:-Scripts}"
FILES=(runmilo.py milosum.py prepmilo.py plot_traj.py
       test_runmilo.sh test_milosum.sh install_milo.sh)

echo "$HOST:$DEST <- $SRC"
ssh "$HOST" "mkdir -p '$DEST/examples'" || exit 1
rsync -e ssh -q "${FILES[@]/#/$SRC/}" "$HOST:$DEST/" || exit 1
rsync -e ssh -q "$SRC/examples/DA_example.in" "$HOST:$DEST/examples/" || exit 1
ssh "$HOST" "chmod +x '$DEST'/*.py '$DEST'/*.sh"
echo "--- suites on Hoffman2 ---"
ssh "$HOST" "bash -lc 'bash ~/$DEST/test_runmilo.sh 2>&1 | tail -1; \
                        bash ~/$DEST/test_milosum.sh 2>&1 | tail -1'"
