#!/usr/bin/env bash
# Signing gate for a built app bundle (see docs/notarization.md).
#
#   check-signing.sh <path/App.app> <path/App.entitlements> [--team <id>]
#
# Prints PASS or FAIL per check and exits 1 when any check fails. Reads files only: it never
# launches the app and needs no network.
#
#   hardened      the app and every nested Mach-O have the hardened runtime flag, which
#                 codesign -dv prints as flags=0x10000(runtime)
#   entitlements  the entitlements in the app's signature equal the checked-in file
#   usage         each device entitlement has its Info.plist usage string (audio-input needs
#                 NSMicrophoneUsageDescription, camera needs NSCameraUsageDescription)
#   team          the app and every nested Mach-O have the same TeamIdentifier (default
#                 8N9KUZLT8N)
#   timestamp     when the app is signed with a Developer ID certificate, it has a secure
#                 timestamp (notarization requires one)
set -uo pipefail

TEAM=8N9KUZLT8N
APP="" ENT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --team) [ $# -ge 2 ] || exit 2; TEAM=$2; shift 2 ;;
    *) if [ -z "$APP" ]; then APP=$1; elif [ -z "$ENT" ]; then ENT=$1; else exit 2; fi; shift ;;
  esac
done
if [ -z "$APP" ] || [ -z "$ENT" ]; then
  sed -n '2,15p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2
  exit 2
fi
[ -d "$APP" ] || { echo "no bundle at $APP" >&2; exit 2; }
[ -f "$ENT" ] || { echo "no entitlements file $ENT" >&2; exit 2; }

FAILED=0
pass() { printf 'PASS  %-12s %s\n' "$1" "$2"; }
fail() { printf 'FAIL  %-12s %s\n' "$1" "$2"; FAILED=1; }

# Every Mach-O in the bundle (regular files only, so framework symlinks count once).
MACHOS=()
while IFS= read -r -d '' f; do
  # Captured first: under pipefail, grep -q closing the pipe early fails the writer with SIGPIPE.
  kind=$(file -b "$f"); if [[ $kind == *Mach-O* ]]; then MACHOS+=("$f"); fi
done < <(find "$APP" -type f -print0)

# hardened
bad=""
for target in "$APP" ${MACHOS[@]+"${MACHOS[@]}"}; do
  info=$(codesign -dv "$target" 2>&1)
  if ! printf '%s' "$info" | grep -Eq 'flags=0x[0-9a-f]+\([^)]*runtime[^)]*\)'; then
    bad="$bad [${target#"$APP"/}]"
  fi
done
if [ -z "$bad" ]; then
  pass hardened "app and ${#MACHOS[@]} Mach-O files have the hardened runtime"
else
  fail hardened "no hardened runtime flag on:$bad"
fi

# entitlements
norm() { /usr/bin/python3 -I -c 'import json,plistlib,sys
raw=sys.stdin.buffer.read()
d=plistlib.loads(raw) if raw.strip() else {}
print(json.dumps(d,sort_keys=True))'; }
have=$(codesign -d --entitlements - --xml "$APP" 2>/dev/null | norm 2>&1)
want=$(norm <"$ENT" 2>&1)
if [ -n "$have" ] && [ "$have" = "$want" ]; then
  pass entitlements "$have"
else
  fail entitlements "signed with $have, checked-in $ENT says $want"
fi

# usage
bad=""
for pair in "com.apple.security.device.audio-input:NSMicrophoneUsageDescription" "com.apple.security.device.camera:NSCameraUsageDescription"; do
  if grep -q "\"${pair%%:*}\": true" <<<"$have"; then
    v=$(/usr/libexec/PlistBuddy -c "Print :${pair#*:}" "$APP/Contents/Info.plist" 2>/dev/null || true)
    [ -n "$v" ] || bad="$bad [${pair%%:*} without ${pair#*:}]"
  fi
done
if [ -z "$bad" ]; then pass usage "every device entitlement has its usage string"; else fail usage "$bad"; fi

# team
bad=""
app_team=$(codesign -dv "$APP" 2>&1 | sed -n 's/^TeamIdentifier=//p')
[ "$app_team" = "$TEAM" ] || bad="$bad [app team is '${app_team}', expected $TEAM]"
for target in ${MACHOS[@]+"${MACHOS[@]}"}; do
  t=$(codesign -dv "$target" 2>&1 | sed -n 's/^TeamIdentifier=//p')
  [ "$t" = "$app_team" ] || bad="$bad [${target#"$APP"/}: '${t}']"
done
if [ -z "$bad" ]; then
  pass team "app and ${#MACHOS[@]} Mach-O files are signed by team $app_team"
else
  fail team "$bad"
fi

# timestamp
auth=$(codesign -dvv "$APP" 2>&1 | sed -n 's/^Authority=//p' | head -n 1)
case "$auth" in
  "Developer ID Application:"*)
    sig=$(codesign -dvv "$APP" 2>&1)
    if grep -q '^Timestamp=' <<<"$sig"; then
      pass timestamp "Developer ID with a secure timestamp"
    else
      fail timestamp "Developer ID signature without a secure timestamp"
    fi ;;
  *) pass timestamp "not applicable ($auth), notarization needs a Developer ID certificate" ;;
esac

exit $FAILED
