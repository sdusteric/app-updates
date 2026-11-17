#!/usr/bin/env bash
# Render the install window backgrounds in dmg/ from dmg/window.html, one per app, at 1x and 2x,
# combined into dmg/<Name>.tiff for tools/make-dmg.sh. Run it after changing window.html or a color,
# then commit the .tiff files. Needs Google Chrome (headless; no window opens).
#
# Each field color has a relative luminance near 0.179, the narrow band where Finder's icon labels
# pass 4.5:1 both in light mode (black text) and dark mode (white text). Check a new color with
# the luminance line printed below before committing it.
set -euo pipefail

APPS=(
  "Reel #6A7591"
  "Tidy #258372"
  "Still #7A66CA"
  "Dolly #C24B7B"
)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DMG_DIR="$(cd "$SCRIPT_DIR/../dmg" && pwd)"
CHROME="${CHROME:-/Applications/Google Chrome.app/Contents/MacOS/Google Chrome}"
[ -x "$CHROME" ] || { echo "render-dmg-backgrounds: Chrome not found at $CHROME (set CHROME)" >&2; exit 1; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/dmg-bg.XXXXXX")"
trap '[ -n "${WORK:-}" ] && [ -d "$WORK" ] && rm -rf "$WORK"' EXIT

for entry in "${APPS[@]}"; do
  name="${entry%% *}" color="${entry##* }"
  url="file://$DMG_DIR/window.html?app=$name&field=%23${color#\#}"
  for scale in 1 2; do
    out="$WORK/$name@${scale}x.png"
    "$CHROME" --headless=new --disable-gpu --hide-scrollbars --no-first-run --user-data-dir="$WORK/profile" \
      --window-size=600,360 --force-device-scale-factor="$scale" --screenshot="$out" "$url" >/dev/null 2>&1
    [ -s "$out" ] || { echo "render-dmg-backgrounds: no image for $name at ${scale}x" >&2; exit 1; }
  done
  mv "$WORK/$name@1x.png" "$WORK/$name.png"
  tiffutil -cathidpicheck "$WORK/$name.png" "$WORK/$name@2x.png" -out "$DMG_DIR/$name.tiff" >/dev/null
  python3 -I - "$name" "$color" <<'PY'
import sys
name, color = sys.argv[1], sys.argv[2].lstrip('#')
lin = [(c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4) for c in (int(color[i:i + 2], 16) / 255 for i in (0, 2, 4))]
y = 0.2126 * lin[0] + 0.7152 * lin[1] + 0.0722 * lin[2]
black, white = (y + 0.05) / 0.05, 1.05 / (y + 0.05)
print(f"{name}: dmg/{name}.tiff  luminance {y:.4f}  black labels {black:.2f}:1  white labels {white:.2f}:1")
sys.exit(0 if min(black, white) >= 4.5 else 1)
PY
done
