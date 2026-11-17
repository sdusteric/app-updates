# dmgbuild settings for tools/make-dmg.sh: the install window people see when they open the disk
# image. dmgbuild writes the window's .DS_Store directly, so no Finder window opens while building.
#
# Defines (-D name=value): app (path to App.app), background (a .tiff from dmg/, or empty for none),
# icon (the volume icon, an .icns, or empty).
#
# The layout matches dmg/window.html: a 600x360 pt window, 128 pt icons centered at (150, 190) for
# the app and (450, 190) for Applications.
import os.path

app = defines["app"]  # noqa: F821 (dmgbuild provides `defines`)
app_name = os.path.basename(app)

format = "ULFO"
filesystem = "HFS+"
files = [app]
symlinks = {"Applications": "/Applications"}
# No hide_extensions: it writes Finder info onto the app bundle, which fails codesign --strict
# ("detritus not allowed"). Finder hides .app on its own unless someone shows all extensions.

icon = defines.get("icon") or None  # noqa: F821
background = defines.get("background") or None  # noqa: F821

window_rect = ((200, 140), (600, 360))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
show_icon_preview = False

arrange_by = None
grid_offset = (0, 0)
grid_spacing = 100
label_pos = "bottom"
text_size = 13
icon_size = 128
icon_locations = {app_name: (150, 190), "Applications": (450, 190)}
