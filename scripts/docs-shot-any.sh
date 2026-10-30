#!/bin/bash
# Runs scripts/docs-shot.sh on whichever docs simulator is free, so several writers can capture
# at once without two runs landing on the same device.
#
#   scripts/docs-shot-any.sh [--build] [--keep-app] <spec.json>
#
# Takes "Fillet Docs 1".."4" by an atomic mkdir lock in build/docs-shots/locks, waits while all
# four are busy, and frees the lock when the run ends (also on failure or interrupt).
set -uo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
LOCKS="$ROOT/build/docs-shots/locks"
mkdir -p "$LOCKS"

while :; do
    for n in 1 2 3 4; do
        lock="$LOCKS/sim$n"
        # A lock left by a run that died: its pid file names a process that is gone.
        if [ -f "$lock/pid" ] && ! kill -0 "$(cat "$lock/pid" 2>/dev/null)" 2>/dev/null; then
            rm -rf "$lock"
        fi
        if mkdir "$lock" 2>/dev/null; then
            echo $$ > "$lock/pid"
            trap 'rm -rf "$lock"' EXIT INT TERM
            echo "docs-shot-any: Fillet Docs $n" >&2
            "$ROOT/scripts/docs-shot.sh" "$@" "$n"
            exit $?
        fi
    done
    sleep 5
done
