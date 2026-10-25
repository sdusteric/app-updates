#!/usr/bin/env bash
# Notarize and staple a signed app bundle (see docs/notarization.md).
#
#   notarize.sh --bundle <path/App.app> --final-zip <path.zip> [--dry-run]
#
# Exit codes:
#   0   notarized and stapled; the stapled app is zipped to --final-zip
#   10  nothing was notarized and the release may go on: the bundle is signed with the Apple
#       Development fallback (a warning is printed), or --dry-run finished
#   1   a check or a step failed
#
# Steps when the bundle is signed with a Developer ID Application certificate:
#   1. the keychain profile sdusteric-notary must exist
#   2. ditto zip, then notarytool submit --wait (the notary log is printed when it is not Accepted)
#   3. stapler staple and stapler validate
#   4. spctl -a -t exec -vv must say "Notarized Developer ID"
#   5. ditto zip of the stapled app to --final-zip; publish.sh --zip signs that file
#
# --dry-run runs steps 1 and 2's zip, prints every other command and does not submit.
set -uo pipefail

PROFILE=sdusteric-notary
BUNDLE="" FINAL="" DRY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --bundle) [ $# -ge 2 ] || exit 2; BUNDLE=$2; shift 2 ;;
    --final-zip) [ $# -ge 2 ] || exit 2; FINAL=$2; shift 2 ;;
    --dry-run) DRY=1; shift ;;
    *) echo "usage: notarize.sh --bundle <App.app> --final-zip <path.zip> [--dry-run]" >&2; exit 2 ;;
  esac
done
[ -n "$BUNDLE" ] && [ -n "$FINAL" ] || { echo "usage: notarize.sh --bundle <App.app> --final-zip <path.zip> [--dry-run]" >&2; exit 2; }
[ -d "$BUNDLE" ] || { echo "notarize: no bundle at $BUNDLE" >&2; exit 1; }
BUNDLE="$(cd "$BUNDLE" && pwd -P)"
die() { echo "notarize: $*" >&2; exit 1; }

AUTH=$(codesign -dvv "$BUNDLE" 2>&1 | sed -n 's/^Authority=//p' | head -n 1)
case "$AUTH" in
  "Developer ID Application:"*) ;;
  *)
    echo "WARNING: signed with '${AUTH:-no certificate}', not Developer ID: this build is not notarized and will not open on other Macs"
    exit 10 ;;
esac

# 1. The notary profile. history is a read-only call that also proves the credentials work.
if ! out=$(xcrun notarytool history --keychain-profile "$PROFILE" 2>&1); then
  if printf '%s' "$out" | grep -q 'No Keychain password item found'; then
    die "the app is signed with Developer ID but the keychain profile '$PROFILE' does not exist. Create it with: xcrun notarytool store-credentials $PROFILE --apple-id <id> --team-id 8N9KUZLT8N (see app-updates/docs/notarization.md)"
  elif [ "$DRY" = 1 ]; then
    echo "notarize: could not reach the notary service to test profile '$PROFILE' (dry run, going on): $(printf '%s' "$out" | head -n 1)"
  else
    die "the keychain profile '$PROFILE' did not work: $(printf '%s' "$out" | head -n 3)"
  fi
else
  echo "profile $PROFILE: ok"
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/notarize.XXXXXX")" || die "mktemp failed"
cleanup() { [ -n "${WORK:-}" ] && [ -d "$WORK" ] && rm -rf "$WORK"; }
trap cleanup EXIT
SUBMIT_ZIP="$WORK/$(basename "$BUNDLE" .app)-notarize.zip"

# 2. Zip and submit.
echo "+ ditto -c -k --sequesterRsrc --keepParent $BUNDLE $SUBMIT_ZIP"
ditto -c -k --sequesterRsrc --keepParent "$BUNDLE" "$SUBMIT_ZIP" || die "ditto failed"
if [ "$DRY" = 1 ]; then
  echo "dry run, not submitting. Would run:"
  echo "+ xcrun notarytool submit $SUBMIT_ZIP --keychain-profile $PROFILE --wait --output-format json"
  echo "+ (if not Accepted) xcrun notarytool log <submission id> --keychain-profile $PROFILE"
  echo "+ xcrun stapler staple $BUNDLE"
  echo "+ xcrun stapler validate $BUNDLE"
  echo "+ spctl -a -t exec -vv $BUNDLE   (must say: Notarized Developer ID)"
  echo "+ ditto -c -k --sequesterRsrc --keepParent $BUNDLE $FINAL"
  exit 10
fi

echo "+ xcrun notarytool submit $SUBMIT_ZIP --keychain-profile $PROFILE --wait --output-format json"
RESULT="$WORK/result.json"
xcrun notarytool submit "$SUBMIT_ZIP" --keychain-profile "$PROFILE" --wait --output-format json >"$RESULT"
SUBMIT_RC=$?
cat "$RESULT"
ID=$(/usr/bin/python3 -I -c 'import json,sys
try: print(json.load(open(sys.argv[1])).get("id",""))
except Exception: print("")' "$RESULT")
STATUS=$(/usr/bin/python3 -I -c 'import json,sys
try: print(json.load(open(sys.argv[1])).get("status",""))
except Exception: print("")' "$RESULT")
if [ "$SUBMIT_RC" != 0 ] || [ "$STATUS" != Accepted ]; then
  if [ -n "$ID" ]; then
    echo "+ xcrun notarytool log $ID --keychain-profile $PROFILE"
    xcrun notarytool log "$ID" --keychain-profile "$PROFILE" || true
  fi
  die "notarization failed (status '${STATUS:-none}', exit $SUBMIT_RC)"
fi

# 3. Staple.
echo "+ xcrun stapler staple $BUNDLE"
xcrun stapler staple "$BUNDLE" || die "stapler staple failed"
xcrun stapler validate "$BUNDLE" || die "stapler validate failed"

# 4. Gatekeeper.
echo "+ spctl -a -t exec -vv $BUNDLE"
SPCTL=$(spctl -a -t exec -vv "$BUNDLE" 2>&1)
echo "$SPCTL"
printf '%s' "$SPCTL" | grep -q 'Notarized Developer ID' || die "spctl does not report Notarized Developer ID"

# 5. The final zip, made after stapling so the Sparkle signature covers it.
rm -f "$FINAL"
echo "+ ditto -c -k --sequesterRsrc --keepParent $BUNDLE $FINAL"
ditto -c -k --sequesterRsrc --keepParent "$BUNDLE" "$FINAL" || die "ditto failed"
echo "notarized and stapled: $FINAL"
exit 0
