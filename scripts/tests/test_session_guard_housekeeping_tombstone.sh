#!/usr/bin/env bash
# Regression: a housekeeping semaphore must stay closable across cycles of the
# same fixed (agent, reason) name.
#
# Bug observed 25.11.2026: `close --housekeeping` hardlinks <name>.open to
# <name>.open.closed and unlinks the open, and a stale open is moved to
# <name>.open.stale. Both tombstones stay on disk. Because housekeeping names are
# fixed, the next cycle's .closed was a foreign inode, so
#   1) _locked_open_identity rejected it ("exact identity/terminal state"),
#   2) the terminal hardlink in _terminal_close_no_clobber would reject it too
#      ("already exists with different content"),
#   3) and the stale-open rename collided with the leftover .stale
# — after which the semaphore could never be closed again. `open` now retires
# those tombstones (renaming them to <suffix>.<stamp>.cycle-retired, history kept).
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

GUARD="$ROOT_DIR/scripts/session-guard.sh"
SESSIONS="$TMP_DIR/.iwe-runtime/sessions"
mkdir -p "$SESSIONS" "$TMP_DIR/DS-strategy"
unset IWE_SESSIONS_ROOT

run_guard() {
  IWE_ROOT="$TMP_DIR" IWE_GOVERNANCE_REPO="DS-strategy" bash "$GUARD" "$@"
}

open_sem() { run_guard open --housekeeping day-open --agent testagent; }
close_sem() { run_guard close --housekeeping day-open --agent testagent; }
SEM="$SESSIONS/testagent-housekeeping-day-open.open"

# Cycle 1 establishes a terminal receipt.
open_sem >/dev/null
close_sem >/dev/null
[ -f "$SEM.closed" ] && [ ! -e "$SEM" ] \
  || { echo "FAIL: first cycle left no terminal receipt" >&2; exit 1; }

# A second cycle must close too: this is exactly what broke before the fix.
open_sem >/dev/null
close_sem >/dev/null
[ -f "$SEM.closed" ] && [ ! -e "$SEM" ] \
  || { echo "FAIL: second cycle could not close its semaphore" >&2; exit 1; }
RETIRED_CLOSED=$(find "$SESSIONS" -name "*.closed.*.cycle-retired" | wc -l)
[ "$RETIRED_CLOSED" -ge 1 ] \
  || { echo "FAIL: the previous cycle's .closed was not retired" >&2; exit 1; }

# Legacy leftovers: a foreign .closed and a foreign .stale next to a live open.
# Neither may block the close (a live open cannot be re-opened to rotate them).
open_sem >/dev/null
cp "$SEM" "$TMP_DIR/foreign" && mv "$TMP_DIR/foreign" "$SEM.closed"
cp "$SEM.closed" "$SEM.stale"
close_sem >/dev/null
[ ! -e "$SEM" ] \
  || { echo "FAIL: leftovers kept the semaphore open" >&2; exit 1; }
RETIRED_TOTAL=$(find "$SESSIONS" -name "*.cycle-retired" | wc -l)
[ "$RETIRED_TOTAL" -ge 3 ] \
  || { echo "FAIL: expected .closed and .stale tombstones to be retired (got $RETIRED_TOTAL)" >&2; exit 1; }

# A live semaphore must still refuse a second open (no regression of the TTL guard).
open_sem >/dev/null
if open_sem >"$TMP_DIR/second-open.log" 2>&1; then
  echo "FAIL: open accepted a live housekeeping semaphore" >&2; exit 1
fi
grep -q 'уже есть активная housekeeping-сессия' "$TMP_DIR/second-open.log" \
  || { echo "FAIL: live-semaphore refusal lost its message" >&2; exit 1; }
close_sem >/dev/null
[ ! -e "$SEM" ] \
  || { echo "FAIL: final cycle left the semaphore open" >&2; exit 1; }

echo "PASS: housekeeping semaphores close across cycles despite tombstones"
