#!/bin/sh
# Turns the captures of the specs in this folder (build/docs-shots/print-check-and-export/) into the
# published images in site/src/assets/screens/print-check-and-export/. Run overhangs.json, lay-flat.json,
# printer-menu.json and export-menu.json with scripts/docs-shot-any.sh first.
set -e
cd "$(dirname "$0")/../../../build/docs-shots/print-check-and-export"
O=../../../site/src/assets/screens/print-check-and-export
# Viewport and inspector, below the tool strip.
magick overhangs.png -crop 2229x1400+503+312 +repage -resize 1600x -strip $O/overhangs.png
magick lay-flat-select.png -crop 2229x1400+503+312 +repage -resize 1600x -strip $O/lay-flat-select.png
# The whole window below the tool strip, so the timeline shows the new Lay Flat 1 step.
magick laid-flat.png -crop 2732x1688+0+312 +repage -resize 1600x -strip $O/laid-flat.png
# The menus, top right.
magick printer-menu.png -crop 742x1060+1990+52 +repage -strip $O/printer-menu.png
magick export-menu.png -crop 742x290+1990+52 +repage -strip $O/export-menu.png
