#!/bin/bash
# Opens a 3MF in the real Bambu Studio app, checks it loads without prompts, slices it, and
# screenshots the window in the prepare view and the slice preview; then quits Bambu Studio.
#
#   scripts/bambu-gui-check.sh model.3mf [--out DIR] [--timeout 300] [--wait 1200]
#
# Only one agent drives the GUI at a time: the script holds the lock directory
# build/texture-lab/bambu.lock while it runs (removed on exit; a lock older than 15 minutes is
# stale and taken over). It waits up to --wait seconds for the lock and for a Bambu Studio that
# someone else left running to quit.
#
# Any dialog window Bambu raises (merge objects, units, mesh errors/repair, load failures, …) is
# screenshotted (dialog-N.png), read with OCR, dismissed with Return, and counted as a failure.
# Two are only noted: Bambu's update offer, and its "load geometry data only" notice that every
# 3MF not written by Bambu Studio itself gets (no Bambu project settings inside). Output folder
# (default build/texture-lab/gui/<name>): prepare.png, preview.png, dialog-*.png, report.txt.
# Prints a one-line PASS/FAIL verdict; exit status 0 = PASS, 1 = FAIL, 2 = usage/lock problems.
#
# Needs Screen Recording (screencapture -l) and Accessibility (keystrokes via System Events)
# permission for the terminal that runs it.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LAB="$ROOT/build/texture-lab"
LOCK="$LAB/bambu.lock"
APP="BambuStudio"
# Bambu's windows belong to "Bambu Studio" (with a space); its process is BambuStudio.
OWNER="Bambu Studio"
TIMEOUT=300
WAIT=1200
OUT=""
INPUT=""

while [ $# -gt 0 ]; do
    case "$1" in
        --out) OUT="$2"; shift 2 ;;
        --timeout) TIMEOUT="$2"; shift 2 ;;
        --wait) WAIT="$2"; shift 2 ;;
        -h|--help) sed -n '2,19p' "$0"; exit 0 ;;
        *) INPUT="$1"; shift ;;
    esac
done
[ -n "$INPUT" ] && [ -f "$INPUT" ] || { echo "usage: $0 model.3mf [--out DIR] [--timeout 300] [--wait 1200]" >&2; exit 2; }
INPUT="$(cd "$(dirname "$INPUT")" && pwd)/$(basename "$INPUT")"
NAME="$(basename "${INPUT%.*}")"
OUT="${OUT:-$LAB/gui/$NAME}"
mkdir -p "$LAB" && rm -rf "$OUT" && mkdir -p "$OUT"
REPORT="$OUT/report.txt"
: > "$REPORT"
log() { echo "$(date +%H:%M:%S) $*" >> "$REPORT"; }

# Helpers built from scripts/: a window lister (CGWindowList: id, layer, x, y, w, h, title) and
# Vision OCR to read what a dialog says.
WINDOWS="$LAB/tools/window-list"
OCR="$LAB/tools/ocr"
mkdir -p "$LAB/tools"
for tool in window-list ocr; do
    if [ ! -x "$LAB/tools/$tool" ] || [ "$ROOT/scripts/$tool.swift" -nt "$LAB/tools/$tool" ]; then
        swiftc -O "$ROOT/scripts/$tool.swift" -o "$LAB/tools/$tool" 2>>"$REPORT" || { echo "FAIL couldn't build $tool"; exit 2; }
    fi
done

# --- Lock -------------------------------------------------------------------------------------
HAVE_LOCK=0
STARTED_APP=0
cleanup() {
    if [ "$STARTED_APP" = 1 ]; then quit_app; fi
    if [ "$HAVE_LOCK" = 1 ]; then rm -rf "$LOCK"; fi
}
trap cleanup EXIT
trap 'exit 130' INT TERM

deadline=$(( $(date +%s) + WAIT ))
until mkdir "$LOCK" 2>/dev/null; do
    age=$(( $(date +%s) - $(stat -f %m "$LOCK" 2>/dev/null || date +%s) ))
    if [ "$age" -gt 900 ]; then
        echo "taking over a stale lock ($age s old: $(cat "$LOCK/owner" 2>/dev/null))" >&2
        rm -rf "$LOCK"; continue
    fi
    [ "$(date +%s)" -lt "$deadline" ] || { echo "FAIL $NAME: Bambu Studio GUI lock held by $(cat "$LOCK/owner" 2>/dev/null) for ${WAIT}s"; exit 2; }
    sleep 5
done
HAVE_LOCK=1
echo "pid $$, $(date -u +%FT%TZ), $INPUT" > "$LOCK/owner"
log "lock taken"

# --- Helpers ----------------------------------------------------------------------------------
app_pid() { pgrep -x "$APP" | head -1; }
# Normal and floating windows (dialogs float at layer 3 or 8), not menus or tooltips.
all_windows() { "$WINDOWS" "$OWNER" | awk -F'\t' '$2 < 20'; }
windows() { all_windows | awk -F'\t' '$2 == 0'; }
main_window() { windows | awk -F'\t' '{print $5 * $6 "\t" $0}' | sort -rn | head -1 | cut -f2-; }
keystroke() { osascript -e "tell application \"$APP\" to activate" -e "delay 0.3" \
    -e "tell application \"System Events\" to tell process \"$APP\" to $1" >>"$REPORT" 2>&1; }

quit_app() {
    local pid; pid="$(app_pid)"
    [ -z "$pid" ] && return
    osascript -e "tell application \"$APP\" to quit" >/dev/null 2>&1 &
    for _ in $(seq 1 20); do
        sleep 0.5
        [ -z "$(app_pid)" ] && return
        # An unsaved-project prompt: "Don't save" (⌘D), else Escape.
        if [ "$(all_windows | wc -l)" -gt 1 ]; then keystroke 'keystroke "d" using command down'; fi
    done
    kill "$pid" 2>/dev/null; sleep 2
    [ -n "$(app_pid)" ] && kill -9 "$pid" 2>/dev/null
}

DIALOGS=()
NOTES=()
dialog_count=0
# Screenshots, records and dismisses every window besides the main one.
handle_dialogs() {
    local main; main="$(main_window | cut -f1)"
    local found=0 escape=0 found_notice=0
    while IFS=$'\t' read -r id layer x y w h title; do
        [ -z "$id" ] || [ "$id" = "$main" ] && continue
        [ "$w" -lt 120 ] || [ "$h" -lt 60 ] && continue   # tooltips, popovers
        # Progress windows come and go by themselves (Return/Escape would press Cancel).
        case "$title" in Loading*|*Slicing*|*rogress*|*Exporting*) continue ;; esac
        dialog_count=$(( dialog_count + 1 ))
        local shot="$OUT/dialog-$dialog_count.png"
        screencapture -x -R "$x,$y,$w,$h" "$shot" 2>>"$REPORT"
        local text; text="$("$OCR" "$shot" 2>/dev/null | tr '\n' ' ' | sed 's/  */ /g; s/ $//')"
        log "dialog $dialog_count: id $id layer $layer “${title}” ${w}x${h}: $text"
        case "$title $text" in
            # Not about the model: Bambu's own update offer. Escape, so nothing gets downloaded.
            *"New version"*|*"new version"*|*Update*|*update*)
                NOTES+=("ignored update offer (dialog-$dialog_count.png)"); escape=1 ;;
            # Bambu's notice for every 3MF another app wrote (no Bambu project settings inside):
            # the geometry loads with the current printer/process. Not a problem with the mesh.
            *"load geometry data only"*)
                NOTES+=("origin notice “${text}” (dialog-$dialog_count.png)"); found_notice=1 ;;
            *)
                DIALOGS+=("“${title:-untitled}”: ${text:-no text} (${w}×${h}, dialog-$dialog_count.png)"); found=1 ;;
        esac
    done <<< "$(all_windows)"
    if [ "$escape" = 1 ]; then keystroke 'key code 53'; sleep 1; fi
    if [ "$found" = 1 ] || [ "$found_notice" = 1 ]; then
        keystroke 'key code 36'   # Return: the default button
        sleep 1
        [ "$(all_windows | wc -l)" -gt 1 ] && { keystroke 'key code 53'; sleep 1; }   # Escape
    fi
}

# --- A Bambu Studio someone else left open ----------------------------------------------------
if [ -n "$(app_pid)" ]; then
    log "Bambu Studio already running (pid $(app_pid)); waiting up to 300 s for it to quit"
    for _ in $(seq 1 60); do [ -z "$(app_pid)" ] && break; sleep 5; done
    if [ -n "$(app_pid)" ]; then log "quitting the leftover Bambu Studio"; quit_app; fi
fi

# --- Open -------------------------------------------------------------------------------------
for _ in $(seq 1 20); do [ -z "$(app_pid)" ] && break; sleep 0.5; done
caffeinate -u -t 5 >/dev/null 2>&1 &
TMP_ROOT="$(getconf DARWIN_USER_TEMP_DIR)bamboo_model"
STARTED_APP=1
# Bambu Studio takes 40 s to 2+ minutes to start (splash, sign-in, network); reopen only if it isn't running at all.
open -a "$APP" "$INPUT" || { echo "FAIL $NAME: couldn't open Bambu Studio"; exit 1; }
log "opened $INPUT"
for i in $(seq 1 420); do
    sleep 1
    m="$(main_window)"
    [ -n "$m" ] && [ "$(echo "$m" | cut -f6)" -gt 500 ] && break
    if [ "$i" = 30 ] && [ -z "$(app_pid)" ]; then open -a "$APP" "$INPUT"; log "reopened"; fi
    # Bambu's wxWidgets start can stall before its first window (0 windows, 0% CPU) until the app
    # receives any event; a display change or a mouse move used to free it. Nudge it with a Shift
    # press (a no-op key) every 10 s while it is running without a window.
    if [ $(( i % 10 )) = 5 ] && [ -n "$(app_pid)" ]; then
        osascript -e "tell application \"System Events\" to key code 56" >>"$REPORT" 2>&1
        [ "$i" = 15 ] && log "no window after ${i}s: nudging with Shift every 10 s"
    fi
done
PID="$(app_pid)"
[ -n "$PID" ] && [ -n "$(main_window)" ] || { echo "FAIL $NAME: Bambu Studio window never appeared"; exit 1; }
log "main window: $(main_window) (pid $PID)"

# Let the model load (its progress window closes), catching prompts as they come.
for _ in $(seq 1 120); do
    sleep 1
    all_windows | cut -f7 | grep -qE '^Loading' || break
done
for _ in $(seq 1 6); do sleep 1; handle_dialogs; done
MAIN="$(main_window | cut -f1)"
screencapture -x -o -l "$MAIN" "$OUT/prepare.png"
log "prepare screenshot"

# --- Slice (⌘R: Slice plate) and wait for the G-code ------------------------------------------
keystroke 'keystroke "r" using command down'
log "slice requested"
START=$(date +%s)
GCODE=""
last=-1
SLICED=0
while [ $(( $(date +%s) - START )) -lt "$TIMEOUT" ]; do
    sleep 2
    handle_dialogs
    GCODE="$(ls -t "$TMP_ROOT"/*/*"#$PID#"*/Metadata/.*.gcode 2>/dev/null | head -1)"
    if [ -n "$GCODE" ]; then
        size=$(stat -f %z "$GCODE" 2>/dev/null || echo 0)
        if [ "$size" -gt 0 ] && [ "$size" = "$last" ]; then SLICED=1; break; fi
        last=$size
    fi
done
SLICE_SECONDS=$(( $(date +%s) - START ))
sleep 3   # let the preview draw
handle_dialogs
MAIN="$(main_window | cut -f1)"
screencapture -x -o -l "$MAIN" "$OUT/preview.png"
log "preview screenshot"

SUMMARY=""
if [ "$SLICED" = 1 ]; then
    LAYERS="$(grep -a -m1 'total layer number' "$GCODE" | sed 's/.*: *//')"
    PTIME="$(grep -a -m1 'total estimated time' "$GCODE" | sed 's/.*total estimated time: *//')"
    SUMMARY="sliced in ${SLICE_SECONDS}s: ${LAYERS:-?} layers, ${PTIME:-?}"
    cp "$GCODE" "$OUT/plate.gcode" 2>/dev/null
fi

quit_app
STARTED_APP=0
log "quit"

PROBLEMS=()
[ "$SLICED" = 1 ] || PROBLEMS+=("no G-code after ${TIMEOUT}s")
[ ${#DIALOGS[@]} -gt 0 ] && PROBLEMS+=("${#DIALOGS[@]} dialog(s): ${DIALOGS[*]}")
NOTE=""
[ ${#NOTES[@]} -gt 0 ] && NOTE=" (note: ${NOTES[*]})"
if [ ${#PROBLEMS[@]} -eq 0 ]; then
    VERDICT="PASS $NAME: loaded with no model prompts, $SUMMARY$NOTE"
else
    VERDICT="FAIL $NAME: $(IFS='; '; echo "${PROBLEMS[*]}")${SUMMARY:+; $SUMMARY}$NOTE"
fi
echo "$VERDICT" | tee -a "$REPORT"
echo "screenshots: $OUT/prepare.png $OUT/preview.png"
[ ${#PROBLEMS[@]} -eq 0 ]
