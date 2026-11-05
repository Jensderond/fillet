#!/bin/bash
# Slices a 3MF (or STL) headlessly with the Bambu Studio CLI and reports PASS/FAIL.
#
#   scripts/slice-check.sh model.3mf [--machine "Bambu Lab A1 mini 0.4 nozzle"]
#                                    [--process "0.20mm Standard @BBL A1M"]
#                                    [--filament "Bambu PLA Basic @BBL A1M"] [--out DIR]
#
# Checks, in order: Bambu's own mesh analysis (`--info`: every object manifold), then a full
# slice of every plate with flattened system presets (scripts/bambu-profiles.py). PASS needs a
# manifold mesh, return code 0, a G-code file and no [error] lines; warnings are listed.
# The G-code and Bambu's result.json stay in the output folder
# (default build/texture-lab/slices/<name>). Exit status 0 = PASS, 1 = FAIL, 2 = usage.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BAMBU="/Applications/BambuStudio.app/Contents/MacOS/BambuStudio"
MACHINE="Bambu Lab A1 mini 0.4 nozzle"
PROCESS="0.20mm Standard @BBL A1M"
FILAMENT="Bambu PLA Basic @BBL A1M"
OUT=""
INPUT=""

while [ $# -gt 0 ]; do
    case "$1" in
        --machine) MACHINE="$2"; shift 2 ;;
        --process) PROCESS="$2"; shift 2 ;;
        --filament) FILAMENT="$2"; shift 2 ;;
        --out) OUT="$2"; shift 2 ;;
        -h|--help) sed -n '2,13p' "$0"; exit 0 ;;
        *) INPUT="$1"; shift ;;
    esac
done
[ -n "$INPUT" ] && [ -f "$INPUT" ] || { echo "usage: $0 model.3mf [--machine …] [--process …] [--filament …] [--out DIR]" >&2; exit 2; }
[ -x "$BAMBU" ] || { echo "FAIL Bambu Studio not found at $BAMBU" ; exit 1; }

INPUT="$(cd "$(dirname "$INPUT")" && pwd)/$(basename "$INPUT")"
NAME="$(basename "${INPUT%.*}")"
OUT="${OUT:-$ROOT/build/texture-lab/slices/$NAME}"
rm -rf "$OUT" && mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"   # absolute: the steps below run Bambu from inside it
PROFILES="$OUT/profiles"
python3 "$ROOT/scripts/bambu-profiles.py" "$PROFILES" --machine "$MACHINE" --process "$PROCESS" --filament "$FILAMENT" >/dev/null \
    || { echo "FAIL couldn't flatten the Bambu presets"; exit 1; }

PROBLEMS=()

# 1. Bambu's mesh analysis.
(cd "$OUT" && "$BAMBU" --info "$INPUT" > "$OUT/info.log" 2>&1)   # it writes result.json into the current folder
INFO="$(grep -vE '\[(trace|debug|info)\]' "$OUT/info.log")"
FACETS="$(echo "$INFO" | awk -F' = ' '/number_of_facets/ {s += $2} END {print s+0}')"
SIZE="$(echo "$INFO" | awk -F' = ' '/^size_[xyz]/ {printf "%s%.1f", (n++ ? " × " : ""), $2} END {print ""}')"
if echo "$INFO" | grep -q "manifold = no"; then PROBLEMS+=("Bambu reports a non-manifold mesh"); fi
for key in open_edges edges_fixed facets_removed facets_reversed backwards_edges; do
    n="$(echo "$INFO" | awk -F' = ' -v k="$key" '$1 == k {s += $2} END {print s+0}')"
    [ "$n" != "0" ] && PROBLEMS+=("$key = $n")
done

# 2. Slice all plates.
START=$(date +%s)
"$BAMBU" --debug 2 --load-settings "$PROFILES/machine.json;$PROFILES/process.json" \
    --load-filaments "$PROFILES/filament.json" --arrange 0 --orient 0 --slice 0 --outputdir "$OUT" "$INPUT" \
    > "$OUT/slice.log" 2>&1
STATUS=$?
SECONDS_TAKEN=$(( $(date +%s) - START ))
RESULT="$OUT/result.json"
CODE="$(python3 -c "import json,sys; print(json.load(open(sys.argv[1])).get('return_code', '?'))" "$RESULT" 2>/dev/null || echo "?")"
MESSAGE="$(python3 -c "import json,sys; print(json.load(open(sys.argv[1])).get('error_string', ''))" "$RESULT" 2>/dev/null || echo "")"
GCODE="$(ls "$OUT"/*.gcode 2>/dev/null | head -1)"
[ "$STATUS" != "0" ] && PROBLEMS+=("Bambu Studio exited with $STATUS")
[ "$CODE" != "0" ] && PROBLEMS+=("return_code $CODE: $MESSAGE")
[ -z "$GCODE" ] && PROBLEMS+=("no G-code written")
ERRORS="$(grep -E '\[error\]' "$OUT/slice.log" | sed -E 's/^\[[^]]*\] \[[^]]*\] \[error\] *//' | sort -u)"
[ -n "$ERRORS" ] && while IFS= read -r line; do PROBLEMS+=("error: $line"); done <<< "$ERRORS"
# Warnings Bambu always prints in CLI mode are not about the model.
WARNINGS="$(grep -E '\[warning\]' "$OUT/slice.log" | sed -E 's/^\[[^]]*\] \[[^]]*\] \[warning\] *//' \
    | grep -vE '^cli mode|no filament colors found|tree support default to organic' | sort -u)"

SUMMARY="$FACETS facets, size $SIZE mm, sliced in ${SECONDS_TAKEN}s"
if [ -n "$GCODE" ]; then
    LAYERS="$(grep -m1 'total layer number' "$GCODE" | sed 's/.*: *//')"
    TIME="$(grep -m1 'total estimated time' "$GCODE" | sed 's/.*total estimated time: *//')"
    GRAMS="$(grep -m1 'total filament weight' "$GCODE" | sed 's/.*: *//')"
    SUMMARY="$SUMMARY, $LAYERS layers, $TIME, ${GRAMS} g"
fi

if [ ${#PROBLEMS[@]} -eq 0 ]; then
    echo "PASS $NAME: $SUMMARY"
else
    echo "FAIL $NAME: $(IFS='; '; echo "${PROBLEMS[*]}"); $SUMMARY"
fi
if [ -n "$WARNINGS" ]; then
    echo "warnings:"
    echo "$WARNINGS" | sed 's/^/  /'
fi
echo "output: $OUT"
[ ${#PROBLEMS[@]} -eq 0 ]
