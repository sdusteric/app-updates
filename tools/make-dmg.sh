#!/usr/bin/env bash
# Make the disk image people download for a first install (see docs/notarization.md).
#
#   make-dmg.sh --bundle <path/App.app> --out <path.dmg> [--dry-run]
#
# The image holds the app and an Applications link in a laid-out window (dmg/, tools/dmg-settings.py),
# so people drag the app out of Downloads,
# where Sparkle cannot always update it. Sparkle updates keep using the zip.
#
# Exit codes:
#   0   the image is signed with the app's Developer ID certificate, notarized and stapled
#   10  the image was made but not signed or notarized: the bundle is not signed with
#       Developer ID (nobody else could open it), or --dry-run (the commands are printed)
#   1   a check or a step failed
set -uo pipefail

PROFILE=sdusteric-notary
BUNDLE="" OUT="" DRY=0
usage() { echo "usage: make-dmg.sh --bundle <App.app> --out <path.dmg> [--dry-run]" >&2; exit 2; }
while [ $# -gt 0 ]; do
  case "$1" in
    --bundle) [ $# -ge 2 ] || usage; BUNDLE=$2; shift 2 ;;
    --out) [ $# -ge 2 ] || usage; OUT=$2; shift 2 ;;
    --dry-run) DRY=1; shift ;;
    *) usage ;;
  esac
done
[ -n "$BUNDLE" ] && [ -n "$OUT" ] || usage
die() { echo "make-dmg: $*" >&2; exit 1; }
[ -d "$BUNDLE" ] || die "no bundle at $BUNDLE"
BUNDLE="$(cd "$BUNDLE" && pwd -P)"
NAME="$(basename "$BUNDLE" .app)"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/make-dmg.XXXXXX")" || die "mktemp failed"
cleanup() { [ -n "${WORK:-}" ] && [ -d "$WORK" ] && rm -rf "$WORK"; }
trap cleanup EXIT

# 1. The image: the app and a link to /Applications in a laid-out window (tools/dmg-settings.py),
# compressed with LZFSE. dmgbuild writes the window's .DS_Store itself, so no Finder window opens.
# The background is dmg/<Name>.tiff when there is one (tools/render-dmg-backgrounds.sh), else none.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VENV="$ROOT/vendor/dmgbuild"
if [ ! -x "$VENV/bin/dmgbuild" ]; then
  echo "+ setting up $VENV from tools/dmg-requirements.txt (pinned hashes)"
  python3 -m venv "$VENV" || die "python3 -m venv failed"
  "$VENV/bin/pip" install -q --disable-pip-version-check --require-hashes --no-deps --only-binary :all: \
    -r "$ROOT/tools/dmg-requirements.txt" || { rm -rf "$VENV"; die "installing dmgbuild failed"; }
fi
BACKGROUND=""
[ -f "$ROOT/dmg/$NAME.tiff" ] && BACKGROUND="$ROOT/dmg/$NAME.tiff"
ICON_FILE="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' "$BUNDLE/Contents/Info.plist" 2>/dev/null || true)"
VOLICON=""
[ -n "$ICON_FILE" ] && [ -f "$BUNDLE/Contents/Resources/${ICON_FILE%.icns}.icns" ] && VOLICON="$BUNDLE/Contents/Resources/${ICON_FILE%.icns}.icns"
rm -f "$OUT"
echo "+ dmgbuild -s tools/dmg-settings.py -D app=$BUNDLE -D background=${BACKGROUND:-none} $NAME $OUT"
"$VENV/bin/dmgbuild" -s "$ROOT/tools/dmg-settings.py" -D app="$BUNDLE" -D background="$BACKGROUND" \
  -D icon="$VOLICON" "$NAME" "$OUT" >"$WORK/dmgbuild.log" 2>&1 || { cat "$WORK/dmgbuild.log" >&2; die "dmgbuild failed"; }
[ -f "$OUT" ] || die "dmgbuild made no image"

AUTH=$(codesign -dvv "$BUNDLE" 2>&1 | sed -n 's/^Authority=//p' | head -n 1)
case "$AUTH" in
  "Developer ID Application:"*) ;;
  *)
    echo "WARNING: $NAME is signed with '${AUTH:-no certificate}', not Developer ID: the disk image is not signed or notarized"
    exit 10 ;;
esac

if [ "$DRY" = 1 ]; then
  echo "dry run, not signing or submitting. Would run:"
  echo "+ codesign --force --timestamp -s \"$AUTH\" $OUT"
  echo "+ xcrun notarytool submit $OUT --keychain-profile $PROFILE --wait --output-format json"
  echo "+ xcrun stapler staple $OUT"
  echo "+ spctl -a -t open --context context:primary-signature -vv $OUT   (must say: Notarized Developer ID)"
  exit 10
fi

# 2. Sign with the same certificate as the app.
echo "+ codesign --force --timestamp -s \"$AUTH\" $OUT"
codesign --force --timestamp -s "$AUTH" "$OUT" || die "codesign failed"

# 3. Notarize. The app inside was notarized on its own already; the image needs its own ticket.
echo "+ xcrun notarytool submit $OUT --keychain-profile $PROFILE --wait --output-format json"
RESULT="$WORK/result.json"
xcrun notarytool submit "$OUT" --keychain-profile "$PROFILE" --wait --output-format json >"$RESULT"
SUBMIT_RC=$?
cat "$RESULT"
field() { /usr/bin/python3 -I -c 'import json,sys
try: print(json.load(open(sys.argv[1])).get(sys.argv[2],""))
except Exception: print("")' "$RESULT" "$1"; }
ID=$(field id)
STATUS=$(field status)
if [ "$SUBMIT_RC" != 0 ] || [ "$STATUS" != Accepted ]; then
  if [ -n "$ID" ]; then
    echo "+ xcrun notarytool log $ID --keychain-profile $PROFILE"
    xcrun notarytool log "$ID" --keychain-profile "$PROFILE" || true
  fi
  die "notarization failed (status '${STATUS:-none}', exit $SUBMIT_RC)"
fi

# 4. Staple and check Gatekeeper.
echo "+ xcrun stapler staple $OUT"
xcrun stapler staple "$OUT" || die "stapler staple failed"
xcrun stapler validate "$OUT" || die "stapler validate failed"
echo "+ spctl -a -t open --context context:primary-signature -vv $OUT"
SPCTL=$(spctl -a -t open --context context:primary-signature -vv "$OUT" 2>&1)
echo "$SPCTL"
printf '%s' "$SPCTL" | grep -q 'Notarized Developer ID' || die "spctl does not report Notarized Developer ID"
echo "notarized and stapled: $OUT"
exit 0
