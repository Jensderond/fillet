#!/bin/bash
# Crops the published images in src/assets/screens/patterns/ from the full captures that the specs
# here write to build/docs-shots/patterns/. Run the specs first (scripts/docs-shot-any.sh <spec>).
set -euo pipefail
cd "$(dirname "$0")/../../../build/docs-shots/patterns"
O=../../../site/src/assets/screens/patterns
# feature-pattern-timeline.json, circular-pattern.json, body-pattern.json: result + inspector pairs
magick feature-pattern-full.png -crop 1352x1271+410+437 +repage -resize 1100x -strip $O/linear-result.png
magick feature-pattern-full.png -crop 614x1086+2104+335 +repage -strip $O/linear-inspector.png
magick circular-full.png -crop 1352x1271+340+437 +repage -resize 1100x -strip $O/circular-result.png
magick circular-full.png -crop 614x1086+2104+335 +repage -strip $O/circular-inspector.png
magick body-pattern-full.png -crop 1352x1284+519+328 +repage -resize 1100x -strip $O/bodies-result.png
magick body-pattern-full.png -crop 614x976+2104+335 +repage -strip $O/bodies-inspector.png
# station-menu.json: the long-press menu on Extrude 2
magick station-menu-full.png -crop 745x758+546+1223 +repage -strip $O/station-menu.png
# timeline-refused.json: the timeline as a picker (picked, can join, can't join)
magick timeline-refused-full.png -crop 575x150+565+1848 +repage -strip $O/timeline-picker.png
# parameter-count.json: the Count and Spacing fields with length = 80 (= 4)
magick parameter-full.png -crop 620x300+2104+1200 +repage -strip $O/parameter-count.png
# parameter-grow.json: length raised to 120, so six holes (parameter cards + result)
magick parameter-grow-full.png -crop 482x637+11+801 +repage -strip $O/parameter-grow-values.png
magick parameter-grow-full.png -crop 1315x836+740+712 +repage -resize 1100x -strip $O/parameter-grow-result.png
