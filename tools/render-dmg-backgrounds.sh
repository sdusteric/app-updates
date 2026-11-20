#!/usr/bin/env bash
# Render the install window backgrounds in dmg/, one per app, at 1x and 2x, combined into
# dmg/<Name>.tiff for tools/make-dmg.sh. Run it after changing a page or a color, then commit the
# .tiff files. Needs Google Chrome (headless; no window opens) and, for an app with its own page,
# ImageMagick (magick).
#
#   render-dmg-backgrounds.sh [Name ...]   (no names: every app)
#
# Most apps share dmg/window.html with a field color. An app with its own folder (dmg/kalos/) uses
# its own window.html there. Either way, what lies under Finder's icon labels must have a relative
# luminance near 0.179, the narrow band where the labels pass 4.5:1 both in light mode (black text)
# and dark mode (white text). The check below fails the run otherwise: the field color for the
# shared page, the rendered pixels under both labels for an app's own page.
set -euo pipefail

APPS=(
  "Reel #6A7591"
  "Tidy #258372"
  "Still #7A66CA"
  "Dolly #C24B7B"
  "Kalos own"
)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DMG_DIR="$(cd "$SCRIPT_DIR/../dmg" && pwd)"
CHROME="${CHROME:-/Applications/Google Chrome.app/Contents/MacOS/Google Chrome}"
[ -x "$CHROME" ] || { echo "render-dmg-backgrounds: Chrome not found at $CHROME (set CHROME)" >&2; exit 1; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/dmg-bg.XXXXXX")"
trap '[ -n "${WORK:-}" ] && [ -d "$WORK" ] && rm -rf "$WORK"' EXIT

contrast() { # contrast <name> <what> <luminance>: print both label ratios, fail under 4.5:1
  python3 -I - "$@" <<'PY'
import sys
name, what, y = sys.argv[1], sys.argv[2], float(sys.argv[3])
black, white = (y + 0.05) / 0.05, 1.05 / (y + 0.05)
print(f"{name}: dmg/{name}.tiff  {what} luminance {y:.4f}  black labels {black:.2f}:1  white labels {white:.2f}:1")
sys.exit(0 if min(black, white) >= 4.5 else 1)
PY
}

for entry in "${APPS[@]}"; do
  name="${entry%% *}" color="${entry##* }"
  if [ $# -gt 0 ] && [[ " $* " != *" $name "* ]]; then continue; fi
  lower="$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]')"
  if [ "$color" = own ]; then
    url="file://$DMG_DIR/$lower/window.html"
  else
    url="file://$DMG_DIR/window.html?app=$name&field=%23${color#\#}"
  fi
  for scale in 1 2; do
    out="$WORK/$name@${scale}x.png"
    "$CHROME" --headless=new --disable-gpu --hide-scrollbars --no-first-run --user-data-dir="$WORK/profile" \
      --window-size=600,384 --force-device-scale-factor="$scale" --screenshot="$out" "$url" >/dev/null 2>&1
    [ -s "$out" ] || { echo "render-dmg-backgrounds: no image for $name at ${scale}x" >&2; exit 1; }
  done
  if [ "$color" = own ]; then
    # Under each label: 120x18 pt centered on x 150 and 450, from y 276 (the labels' line).
    for x in 180 780; do
      y=$(magick "$WORK/$name@2x.png" -crop "240x36+$x+552" -colorspace RGB \
        -format '%[fx:0.2126*mean.r+0.7152*mean.g+0.0722*mean.b]' info:)
      contrast "$name" "under the label at x $((x / 2 + 60))" "$y" || exit 1
    done
  else
    y=$(python3 -I -c 'import sys
c = sys.argv[1].lstrip("#")
lin = [(v / 12.92 if v <= 0.04045 else ((v + 0.055) / 1.055) ** 2.4) for v in (int(c[i:i + 2], 16) / 255 for i in (0, 2, 4))]
print(0.2126 * lin[0] + 0.7152 * lin[1] + 0.0722 * lin[2])' "$color")
    contrast "$name" "field" "$y" || exit 1
  fi
  mv "$WORK/$name@1x.png" "$WORK/$name.png"
  tiffutil -cathidpicheck "$WORK/$name.png" "$WORK/$name@2x.png" -out "$DMG_DIR/$name.tiff" >/dev/null
done
