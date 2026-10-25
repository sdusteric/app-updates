#!/bin/bash
# Verify the newest item of an appcast against a zip.
set -euo pipefail

KEY_ACCOUNT="sdusteric-apps"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BIN="$REPO_DIR/vendor/Sparkle-2.10.0/bin"
die() { echo "verify-appcast.sh: error: $*" >&2; exit 1; }

[ $# -eq 2 ] || { echo "usage: verify-appcast.sh <appcast.xml> <zip>" >&2; exit 2; }
APPCAST="$1" ZIP="$2"
[ -f "$APPCAST" ] || die "appcast not found: $APPCAST"
[ -f "$ZIP" ] || die "zip not found: $ZIP"

PUBKEY="$(sed -n 's/.*Public key for Info.plist `SUPublicEDKey`: `\([^`]*\)`.*/\1/p' "$REPO_DIR/CONTRACT.md" | head -n 1)"
[ -n "$PUBKEY" ] || die "could not read the public key from CONTRACT.md"

xmllint --noout "$APPCAST" || die "appcast is not well-formed XML"

# The Keychain key used by sign_update --verify must be the contract key.
KC_PUB="$("$BIN/generate_keys" --account "$KEY_ACCOUNT" -p 2>/dev/null | tail -n 1 | tr -d '[:space:]')"
[ "$KC_PUB" = "$PUBKEY" ] || die "Keychain public key does not match CONTRACT.md"

FIELDS="$(python3 -I - "$APPCAST" <<'PY'
import sys, xml.etree.ElementTree as ET
S = '{http://www.andymatuschak.org/xml-namespaces/sparkle}'
items = ET.parse(sys.argv[1]).getroot().findall('./channel/item')
if not items:
    sys.exit('no items')
best = max(items, key=lambda i: int(i.findtext(S + 'version')))
if best is not items[0]:
    sys.exit('newest build is not the first item')
e = best.find('enclosure')
print(e.get('length'))
print(e.get(S + 'edSignature'))
print(e.get('url'))
PY
)" || die "appcast structure check failed"
LEN="$(printf '%s\n' "$FIELDS" | sed -n 1p)"
SIG="$(printf '%s\n' "$FIELDS" | sed -n 2p)"
URL="$(printf '%s\n' "$FIELDS" | sed -n 3p)"

ACTUAL="$(stat -f%z "$ZIP")"
[ "$LEN" = "$ACTUAL" ] || die "length mismatch: appcast $LEN, file $ACTUAL"
[ "$(basename "$URL")" = "$(basename "$ZIP")" ] || die "enclosure url does not end in $(basename "$ZIP")"
"$BIN/sign_update" --account "$KEY_ACCOUNT" --verify "$ZIP" "$SIG" >/dev/null 2>&1 || die "signature rejected"
echo "verified: $(basename "$ZIP") length=$ACTUAL signature ok"
