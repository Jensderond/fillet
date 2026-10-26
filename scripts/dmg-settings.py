# dmgbuild settings for the Mac release DMG (scripts/release.sh runs dmgbuild with these).
# dmgbuild writes the window layout straight into the image's .DS_Store, so no Finder scripting.
#
#   dmgbuild -s scripts/dmg-settings.py -D app=<Fillet.app> -D background=<tiff> Fillet <out.dmg>
#
# The window and icon positions must match the artwork in docs/dmg/background.swift.
import os.path

app = defines["app"]  # noqa: F821 (dmgbuild provides `defines`)
app_name = os.path.basename(app)

format = "UDZO"
filesystem = "HFS+"
files = [app]
symlinks = {"Applications": "/Applications"}
# The volume shows Fillet's own icon in the Finder sidebar and on the desktop.
icon = os.path.join(app, "Contents", "Resources", "AppIcon.icns")

background = defines["background"]  # noqa: F821
window_rect = ((200, 160), (640, 400))
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
default_view = "icon-view"
show_icon_preview = False
arrange_by = None
icon_size = 112
text_size = 13
icon_locations = {app_name: (192, 192), "Applications": (448, 192)}
hide_extensions = [app_name]
