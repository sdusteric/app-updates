#!/bin/bash
# Offline test for publish.sh and verify-appcast.sh. Uses dry-run mode only.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GOOD_KEY="$(sed -n 's/.*Public key for Info.plist `SUPublicEDKey`: `\([^`]*\)`.*/\1/p' "$ROOT/CONTRACT.md" | head -n 1)"
WRONG_KEY="AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
T="$(mktemp -d)"
trap '[ -d "$T" ] && rm -rf "$T"' EXIT
OUT="$T/out"; mkdir "$OUT"
PASS=0
ok() { echo "ok: $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL: $1" >&2; exit 1; }

make_bundle() { # dir short build key
  local app="$1/Dummy.app"
  mkdir -p "$app/Contents/MacOS"
  printf '#!/bin/sh\necho dummy\n' > "$app/Contents/MacOS/Dummy"
  chmod +x "$app/Contents/MacOS/Dummy"
  cat > "$app/Contents/Info.plist" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>Dummy</string>
<key>CFBundleIdentifier</key><string>com.example.dummy</string>
<key>CFBundleName</key><string>Dummy</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$2</string>
<key>CFBundleVersion</key><string>$3</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>SUPublicEDKey</key><string>$4</string>
</dict></plist>
PL
  codesign --force -s - "$app" >/dev/null 2>&1
}

printf '# Notes\n\n- **Fast** fix for `x` & <y>\n- Second\n\nPlain paragraph.\n' > "$T/notes.md"

B1="$T/b1"; mkdir "$B1"; make_bundle "$B1" 1.0.0 202601010101 "$GOOD_KEY"
B2="$T/b2"; mkdir "$B2"; make_bundle "$B2" 1.0.1 202601020202 "$GOOD_KEY"
B3="$T/b3"; mkdir "$B3"; make_bundle "$B3" 1.0.2 202601010000 "$GOOD_KEY"
B4="$T/b4"; mkdir "$B4"; make_bundle "$B4" 1.0.3 202601030303 "$WRONG_KEY"

"$ROOT/tools/publish.sh" --app dummy --bundle "$B1/Dummy.app" --dry-run "$OUT"
"$ROOT/tools/publish.sh" --app dummy --bundle "$B2/Dummy.app" --notes "$T/notes.md" --dry-run "$OUT"
ok "two dry-run publishes"

[ "$(grep -c '<item>' "$OUT/appcast.xml")" = 2 ] || fail "expected 2 items"
first="$(grep -o '<sparkle:version>[0-9]*' "$OUT/appcast.xml" | head -n 1)"
[ "$first" = "<sparkle:version>202601020202" ] || fail "newest item is not first"
grep -q 'http://127.0.0.1:8765/Dummy-1.0.1-202601020202.zip' "$OUT/appcast.xml" || fail "enclosure url"
grep -q '<li><strong>Fast</strong> fix for <code>x</code> &amp; &lt;y&gt;</li>' "$OUT/appcast.xml" || fail "notes html"
ok "appcast has newest first, local urls, rendered notes"

"$ROOT/tools/verify-appcast.sh" "$OUT/appcast.xml" "$OUT/Dummy-1.0.1-202601020202.zip"
ok "verify-appcast accepts newest zip"

if "$ROOT/tools/verify-appcast.sh" "$OUT/appcast.xml" "$OUT/Dummy-1.0.0-202601010101.zip" >/dev/null 2>&1; then
  fail "verify accepted the wrong zip"
fi
ok "verify-appcast rejects a different zip"

if "$ROOT/tools/publish.sh" --app dummy --bundle "$B3/Dummy.app" --dry-run "$OUT" >/dev/null 2>&1; then
  fail "lower build was accepted"
fi
if "$ROOT/tools/publish.sh" --app dummy --bundle "$B2/Dummy.app" --dry-run "$OUT" >/dev/null 2>&1; then
  fail "equal build was accepted"
fi
ok "lower and equal build numbers refused"

if "$ROOT/tools/publish.sh" --app dummy --bundle "$B4/Dummy.app" --dry-run "$OUT" >/dev/null 2>&1; then
  fail "wrong public key was accepted"
fi
ok "wrong SUPublicEDKey refused"

[ "$(grep -c '<item>' "$OUT/appcast.xml")" = 2 ] || fail "refused runs changed the appcast"
ok "refused runs left the appcast unchanged"
echo "all $PASS checks passed"
