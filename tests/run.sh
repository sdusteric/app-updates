#!/bin/bash
# Offline test for publish.sh and verify-appcast.sh: dry runs, and R2 publishes against a fake wrangler.
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

DMG="$OUT/Dummy-1.0.1.dmg"
[ -f "$DMG" ] || fail "no disk image"
hdiutil verify -quiet "$DMG" || fail "disk image does not verify"
MNT="$T/mnt"; mkdir "$MNT"
hdiutil attach -quiet -nobrowse -noautoopen -readonly -mountpoint "$MNT" "$DMG" || fail "disk image does not attach"
# Checks between attach and detach must not stop the script (set -e), or the image stays mounted.
in_image=0; signed=0
{ [ -x "$MNT/Dummy.app/Contents/MacOS/Dummy" ] && [ "$(readlink "$MNT/Applications")" = /Applications ]; } || in_image=$?
codesign --verify --deep --strict "$MNT/Dummy.app" 2>/dev/null || signed=$?
# The window layout from tools/dmg-settings.py: the app at (150, 208), Applications at (450, 208).
laid_out=0
"$ROOT/vendor/dmgbuild/bin/python" -I - "$MNT/.DS_Store" <<'PY' || laid_out=$?
import sys
from ds_store import DSStore
with DSStore.open(sys.argv[1], "r") as d:
    assert d["Dummy.app"]["Iloc"] == (150, 208), d["Dummy.app"]["Iloc"]
    assert d["Applications"]["Iloc"] == (450, 208), d["Applications"]["Iloc"]
PY
hdiutil detach -quiet "$MNT" || fail "disk image does not detach"
[ "$in_image" = 0 ] || fail "disk image lacks Dummy.app or the Applications link"
[ "$signed" = 0 ] || fail "app in the disk image fails codesign --verify"
[ "$laid_out" = 0 ] || fail "disk image window layout is not the one in tools/dmg-settings.py"
ok "disk image holds the signed app and an Applications link"

PAGE="$OUT/download/index.html"
[ -f "$PAGE" ] || fail "no download page"
grep -q 'content="0; url=http://127.0.0.1:8765/Dummy-1.0.1.dmg"' "$PAGE" || fail "download page does not point at the newest disk image"
grep -q 'Downloading Dummy 1.0.1' "$PAGE" || fail "download page names the wrong version"
xmllint --html --noout "$PAGE" 2>/dev/null || fail "download page does not parse"
ok "download page points at the newest disk image"

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

B5="$T/b5"; mkdir "$B5"; make_bundle "$B5" 1.1.0 202601040404 "$GOOD_KEY"
"$ROOT/tools/publish.sh" --app dummy --bundle "$B5/Dummy.app" --channel beta --dry-run "$OUT" >/dev/null
first_item="$(awk '/<item>/{n++} n==1' "$OUT/appcast.xml")"
echo "$first_item" | grep -q '<sparkle:channel>beta</sparkle:channel>' || fail "beta item has no channel"
[ "$(grep -c '<sparkle:channel>' "$OUT/appcast.xml")" = 1 ] || fail "older items gained a channel"
if "$ROOT/tools/publish.sh" --app dummy --bundle "$B5/Dummy.app" --channel 'Beta 1' --dry-run "$OUT" >/dev/null 2>&1; then
  fail "bad channel name was accepted"
fi
ok "--channel beta marks only the new item"
grep -q 'Dummy-1.0.1.dmg' "$OUT/download/index.html" || fail "a beta release moved the download page"
[ -f "$OUT/Dummy-1.1.0.dmg" ] || fail "beta release has no disk image"
ok "beta release gets a disk image but leaves the download page"
# R2 apps (kalos): dry runs keep the real addresses and make no download page.
R2OUT="$T/r2out"; mkdir "$R2OUT"
"$ROOT/tools/publish.sh" --app kalos --bundle "$B1/Dummy.app" --dry-run "$R2OUT" >/dev/null
grep -q 'url="https://updates.kalosbrowser.com/kalos/Dummy-1.0.0-202601010101.zip"' "$R2OUT/appcast.xml" || fail "R2 enclosure url"
grep -q '<link>https://updates.kalosbrowser.com/kalos/appcast.xml</link>' "$R2OUT/appcast.xml" || fail "R2 feed link"
[ ! -e "$R2OUT/download" ] || fail "an R2 app got a download page"
[ -f "$R2OUT/Dummy-1.0.0-202601010101.dmg" ] || fail "R2 dry run has no disk image"
R2T="$T/r2test"; mkdir "$R2T"
KALOS_UPDATES_BASE="https://pub-x.r2.dev/" "$ROOT/tools/publish.sh" --app kalos --prefix kalos-test --bundle "$B1/Dummy.app" --dry-run "$R2T" >/dev/null
grep -q 'url="https://pub-x.r2.dev/kalos-test/Dummy-1.0.0-202601010101.zip"' "$R2T/appcast.xml" || fail "KALOS_UPDATES_BASE and --prefix"
ok "R2 dry run uses the R2 base and prefix and makes no download page"
for bad in "--app dummy --prefix x" "--app kalos --prefix Bad_Name"; do
  # shellcheck disable=SC2086
  if "$ROOT/tools/publish.sh" $bad --bundle "$B1/Dummy.app" --dry-run "$T/r2test" >/dev/null 2>&1; then fail "accepted: $bad"; fi
done
if KALOS_UPDATES_BASE="http://x.example" "$ROOT/tools/publish.sh" --app kalos --bundle "$B1/Dummy.app" --dry-run "$T/r2test" >/dev/null 2>&1; then
  fail "accepted a plain http R2 base"
fi
ok "--prefix only for R2 apps, checked names and an https base"

# A real R2 publish against a fake wrangler that keeps the bucket in a folder. A fake gh fails,
# so a mistake here can never make a GitHub release.
FAKE="$T/fake"; STORE="$T/bucket"; LOG="$T/wrangler.log"; mkdir -p "$FAKE" "$STORE"
cat > "$FAKE/wrangler" <<'SH'
#!/bin/bash
echo "$*" >> "$FAKE_LOG"
[ "$1 $2" = "r2 object" ] || exit 9
verb="$3" key="$4"; shift 4
file="" remote=0
while [ $# -gt 0 ]; do case "$1" in --file) file="$2"; shift 2 ;; --remote) remote=1; shift ;; *) shift 2 ;; esac; done
[ "$remote" = 1 ] || { echo "not --remote" >&2; exit 8; }
case "$verb" in
  get)
    [ -z "${FAKE_GET_ERROR:-}" ] || { echo "Authentication error [code: 10000]" >&2; : > "$file"; exit 1; }
    : > "$file"
    [ -f "$FAKE_STORE/$key" ] || { echo "✘ [ERROR] The specified key does not exist." >&2; exit 1; }
    cp "$FAKE_STORE/$key" "$file" ;;
  put) mkdir -p "$(dirname "$FAKE_STORE/$key")"; cp "$file" "$FAKE_STORE/$key" ;;
  *) exit 7 ;;
esac
SH
printf '#!/bin/sh\necho "fake gh: $*" >&2\nexit 1\n' > "$FAKE/gh"
chmod +x "$FAKE/wrangler" "$FAKE/gh"
r2pub() { PATH="$FAKE:$PATH" FAKE_LOG="$LOG" FAKE_STORE="$STORE" PUBLISH_WRANGLER="$FAKE/wrangler" "$ROOT/tools/publish.sh" --app kalos "$@"; }

r2pub --bundle "$B1/Dummy.app" >/dev/null
[ -f "$STORE/kalos-updates/kalos/Dummy-1.0.0-202601010101.zip" ] || fail "R2 publish did not upload the zip"
[ "$(grep -c '<item>' "$STORE/kalos-updates/kalos/appcast.xml")" = 1 ] || fail "first R2 appcast"
puts="$(grep '^r2 object put' "$LOG" | awk '{print $4}' | tr '\n' ' ')"
[ "$puts" = "kalos-updates/kalos/Dummy-1.0.0-202601010101.zip kalos-updates/kalos/appcast.xml " ] || fail "upload order: $puts"
grep -q 'appcast.xml .*--cache-control no-cache' "$LOG" || fail "appcast is not no-cache"
ok "first R2 publish uploads the zip, then the appcast"

r2pub --bundle "$B2/Dummy.app" >/dev/null
[ "$(grep -c '<item>' "$STORE/kalos-updates/kalos/appcast.xml")" = 2 ] || fail "second R2 publish dropped the first item"
"$ROOT/tools/verify-appcast.sh" "$STORE/kalos-updates/kalos/appcast.xml" "$STORE/kalos-updates/kalos/Dummy-1.0.1-202601020202.zip" >/dev/null
if r2pub --bundle "$B3/Dummy.app" >/dev/null 2>&1; then fail "R2 accepted a lower build than the bucket's appcast"; fi
before="$(cat "$STORE/kalos-updates/kalos/appcast.xml")"
if FAKE_GET_ERROR=1 r2pub --bundle "$B5/Dummy.app" >/dev/null 2>&1; then fail "R2 publish went on after a failed appcast fetch"; fi
[ "$before" = "$(cat "$STORE/kalos-updates/kalos/appcast.xml")" ] || fail "a failed fetch changed the appcast"
[ ! -e "$STORE/kalos-updates/kalos/Dummy-1.1.0-202601040404.zip" ] || fail "a failed fetch still uploaded"
r2pub --prefix kalos-test --bundle "$B1/Dummy.app" >/dev/null
[ -f "$STORE/kalos-updates/kalos-test/appcast.xml" ] || fail "--prefix did not publish to kalos-test/"
ok "R2 merges with the bucket's appcast, refuses old builds, stops on fetch errors, honors --prefix"

# Public apps release in their own repo, tagged v<short>; the rest stay here, tagged <app>-v<short>-<build>.
OWN="$T/own"; mkdir "$OWN"
line="$("$ROOT/tools/publish.sh" --app snap --bundle "$B1/Dummy.app" --dry-run "$OWN" | grep '^dry-run:')"
[[ "$line" == *"release=sdusteric/still@v1.0.0 "* ]] || fail "snap release target: $line"
OTHER="$T/other"; mkdir "$OTHER"
line="$("$ROOT/tools/publish.sh" --app booth --bundle "$B1/Dummy.app" --dry-run "$OTHER" | grep '^dry-run:')"
[[ "$line" == *"release=sdusteric/app-updates@booth-v1.0.0-202601010101 "* ]] || fail "booth release target: $line"
ok "public apps release in their own repo, private apps here"
echo "all $PASS checks passed"
