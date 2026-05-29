#!/usr/bin/env bash
#
# run_tests.sh — Launch headless LibreOffice, run the integration tests,
#                and clean up afterwards.
#
# Usage:
#   bash run_tests.sh
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

LO_PORT=2002
VENV_DIR=".venv"
SOFFICE_PID=""

# ── Helpers ────────────────────────────────────────────────────────────────

cleanup() {
    echo ""
    echo "── Cleaning up ──────────────────────────────────────────────"

    # Kill the LibreOffice process we started
    if [[ -n "${SOFFICE_PID:-}" ]] && kill -0 "$SOFFICE_PID" 2>/dev/null; then
        echo "Stopping LibreOffice (PID $SOFFICE_PID)..."
        kill "$SOFFICE_PID" 2>/dev/null || true
        wait "$SOFFICE_PID" 2>/dev/null || true
    fi

    # Remove any lock files left over in the project directory
    for lock in "$SCRIPT_DIR"/.~lock.*; do
        [[ -e "$lock" ]] && rm -f "$lock" && echo "Removed lock file: $lock"
    done

    echo "Done."
}
trap cleanup EXIT

# ── Kill any existing LO on the test port ──────────────────────────────────

if lsof -i ":${LO_PORT}" -t &>/dev/null; then
    echo "Killing existing process on port ${LO_PORT}..."
    kill $(lsof -i ":${LO_PORT}" -t) 2>/dev/null || true
    sleep 2
fi

# ── Set up the virtual environment ─────────────────────────────────────────

if [[ ! -d "$VENV_DIR" ]]; then
    echo "Creating virtual environment with system site-packages (for UNO)..."
    python3 -m venv --system-site-packages "$VENV_DIR"
fi

echo "Installing test dependencies..."
"$VENV_DIR/bin/pip" install --quiet -r requirements.txt

# ── Launch LibreOffice headless ────────────────────────────────────────────

echo "Starting LibreOffice Calc (headless) on port ${LO_PORT}..."
soffice \
    --headless \
    --norestore \
    --nologo \
    --calc \
    --accept="socket,host=localhost,port=${LO_PORT};urp;" &
SOFFICE_PID=$!

# Wait until the socket is accepting connections
echo -n "Waiting for LibreOffice to be ready"
for i in $(seq 1 30); do
    if "$VENV_DIR/bin/python3" -c "
import uno, sys
try:
    ctx = uno.getComponentContext()
    resolver = ctx.ServiceManager.createInstanceWithContext(
        'com.sun.star.bridge.UnoUrlResolver', ctx)
    resolver.resolve(
        'uno:socket,host=localhost,port=${LO_PORT};urp;StarOffice.ComponentContext')
    sys.exit(0)
except:
    sys.exit(1)
" 2>/dev/null; then
        echo " ready!"
        break
    fi
    echo -n "."
    sleep 1
done

# Quick sanity check
if ! kill -0 "$SOFFICE_PID" 2>/dev/null; then
    echo ""
    echo "ERROR: LibreOffice failed to start."
    exit 1
fi

# ── Run the tests ──────────────────────────────────────────────────────────

echo ""
echo "── Running integration tests ──────────────────────────────────"
"$VENV_DIR/bin/python3" -m pytest test_macros.py -v "$@"
