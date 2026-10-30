#!/bin/bash
# Like scripts/docs-shot-any.sh (same locks), but tries the simulators in the order given in
# $SIMS (default "2 3 4 1"), so a simulator stuck in a bad state can be skipped.
set -uo pipefail
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
LOCKS="$ROOT/build/docs-shots/locks"
mkdir -p "$LOCKS"
while :; do
    for n in ${SIMS:-2 3 4 1}; do
        lock="$LOCKS/sim$n"
        if [ -f "$lock/pid" ] && ! kill -0 "$(cat "$lock/pid" 2>/dev/null)" 2>/dev/null; then rm -rf "$lock"; fi
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
