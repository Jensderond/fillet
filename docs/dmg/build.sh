#!/bin/bash
# Regenerates the DMG window background (background.swift -> background.tiff, 1x + 2x) and a
# preview. scripts/release.sh packs background.tiff into the DMG via scripts/dmg-settings.py.
set -euo pipefail
cd "$(dirname "$0")"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

swift background.swift "$TMP"
tiffutil -cathidpicheck "$TMP/background.png" "$TMP/background@2x.png" -out background.tiff 2>/dev/null
cp "$TMP/background@2x.png" preview.png
echo "done"
