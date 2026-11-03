#!/usr/bin/env bash
# Make the disk image people download for a first install (see docs/notarization.md).
#
#   make-dmg.sh --bundle <path/App.app> --out <path.dmg> [--dry-run]
#
# The image holds the app and an Applications link, so people drag the app out of Downloads,
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

# 1. The image: the app and a link to /Applications, compressed with LZFSE.
mkdir "$WORK/stage" || die "mkdir failed"
ditto "$BUNDLE" "$WORK/stage/$NAME.app" || die "ditto failed"
ln -s /Applications "$WORK/stage/Applications" || die "ln failed"
rm -f "$OUT"
echo "+ hdiutil create -volname $NAME -srcfolder <app and Applications link> -fs HFS+ -format ULFO $OUT"
hdiutil create -quiet -volname "$NAME" -srcfolder "$WORK/stage" -fs HFS+ -format ULFO -ov "$OUT" || die "hdiutil create failed"

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
