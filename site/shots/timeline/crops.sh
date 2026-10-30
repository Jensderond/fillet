#!/bin/sh
# Turns the captures of the specs in this folder (build/docs-shots/timeline/) into the published
# images in site/src/assets/screens/timeline/. Run the four specs with scripts/docs-shot-any.sh first.
set -e
cd "$(dirname "$0")/../../../build/docs-shots/timeline"
O=../../../site/src/assets/screens/timeline
magick ruler.png -crop 1240x162+0+1852 +repage -strip $O/ruler.png
magick rolled-back.png -crop 2093x1734+0+314 +repage -resize 1600x -strip $O/rolled-back.png
magick station-menu.png -crop 1536x1228+556+820 +repage -resize 1400x -strip $O/station-menu.png
magick failed-banner.png -resize 1600x1200 -strip $O/failed.png
magick failed-step.png -crop 1302x1000+1430+314 +repage -resize 1200x -strip $O/failed-inspector.png
