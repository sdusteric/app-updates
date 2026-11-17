#!/bin/bash
# Publish a signed Sparkle update for one app. See README.md and CONTRACT.md.
set -euo pipefail

REPO_SLUG="sdusteric/app-updates"
KEY_ACCOUNT="sdusteric-apps"
CONTRACT_KEY="PMaW+8sZRzOkfIwy1KBGk0CHTVoN49FE9o8gUlNGdZc="
PAGES_BASE="https://sdusteric.github.io/app-updates"

# Where each app publishes. An app listed here goes to a Cloudflare R2 bucket served from its own domain:
# the files and the appcast go to <bucket>/<prefix>/, with no GitHub Release, commit or download page
# (its own site serves first installs). Every other app uses GitHub Releases and GitHub Pages.
R2_BUCKET="" R2_BASE=""
r2_target() {
  case "$1" in
    kalos) R2_BUCKET="kalos-updates"; R2_BASE="${KALOS_UPDATES_BASE:-https://updates.kalosbrowser.com}" ;;
  esac
}
# Apps whose source is public get their GitHub Release in their own repo, tagged v<short> at the
# commit the build came from (the checkout next to this repo, which must be clean and pushed).
# Private apps keep theirs here, where a private repo's assets would need a login to download.
OWN_REPO=""
github_target() {
  case "$1" in
    reel) OWN_REPO="sdusteric/reel" ;;
    tidy) OWN_REPO="sdusteric/tidy" ;;
    snap) OWN_REPO="sdusteric/still" ;;
    dolly) OWN_REPO="sdusteric/dolly" ;;
  esac
}
# The command that talks to R2. Tests put a fake here.
read -r -a WRANGLER <<<"${PUBLISH_WRANGLER:-pnpm dlx wrangler}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SIGN_UPDATE="$REPO_DIR/vendor/Sparkle-2.10.0/bin/sign_update"

usage() {
  echo "usage: publish.sh --app <app> --bundle <path/App.app> [--notes <file.md>] [--dry-run <dir>] [--port <n>] [--zip <file.zip>] [--channel <name>] [--prefix <name>]" >&2
  exit 2
}
die() { echo "publish.sh: error: $*" >&2; exit 1; }

APP="" BUNDLE="" NOTES="" DRY_DIR="" PORT="8765" GIVEN_ZIP="" CHANNEL="" PREFIX=""
while [ $# -gt 0 ]; do
  case "$1" in
    --app) [ $# -ge 2 ] || usage; APP="$2"; shift 2 ;;
    --bundle) [ $# -ge 2 ] || usage; BUNDLE="$2"; shift 2 ;;
    --notes) [ $# -ge 2 ] || usage; NOTES="$2"; shift 2 ;;
    --dry-run) [ $# -ge 2 ] || usage; DRY_DIR="$2"; shift 2 ;;
    --port) [ $# -ge 2 ] || usage; PORT="$2"; shift 2 ;;
    --zip) [ $# -ge 2 ] || usage; GIVEN_ZIP="$2"; shift 2 ;;
    --channel) [ $# -ge 2 ] || usage; CHANNEL="$2"; shift 2 ;;
    --prefix) [ $# -ge 2 ] || usage; PREFIX="$2"; shift 2 ;;
    *) usage ;;
  esac
done
[ -n "$APP" ] && [ -n "$BUNDLE" ] || usage
[[ "$APP" =~ ^[a-z][a-z0-9-]*$ ]] || die "--app must be lowercase letters, digits and dashes"
[[ "$PORT" =~ ^[0-9]+$ ]] || die "--port must be a number"
# Sparkle offers an item with <sparkle:channel> only to apps that allow that channel; with none, everyone gets it.
[ -z "$CHANNEL" ] || [[ "$CHANNEL" =~ ^[a-z]+$ ]] || die "--channel must be lowercase letters"
r2_target "$APP"
github_target "$APP"
# --prefix publishes somewhere other than <bucket>/<app>/, such as kalos-test/ for an end-to-end test.
[ -z "$PREFIX" ] || [ -n "$R2_BUCKET" ] || die "--prefix is only for apps that publish to R2"
PREFIX="${PREFIX:-$APP}"
[[ "$PREFIX" =~ ^[a-z][a-z0-9-]*$ ]] || die "--prefix must be lowercase letters, digits and dashes"
R2_BASE="${R2_BASE%/}"
[ -z "$R2_BUCKET" ] || [[ "$R2_BASE" =~ ^https://[A-Za-z0-9.-]+$ ]] || die "the R2 base must be https://<host>, got '$R2_BASE'"
[ -d "$BUNDLE" ] || die "bundle not found: $BUNDLE"
[ -x "$SIGN_UPDATE" ] || die "sign_update not found at $SIGN_UPDATE"
[ -z "$NOTES" ] || [ -f "$NOTES" ] || die "notes file not found: $NOTES"
[ -z "$GIVEN_ZIP" ] || [ -f "$GIVEN_ZIP" ] || die "zip not found: $GIVEN_ZIP"
BUNDLE="$(cd "$BUNDLE" && pwd)"
PLIST="$BUNDLE/Contents/Info.plist"
[ -f "$PLIST" ] || die "missing $PLIST"

plist_get() { /usr/libexec/PlistBuddy -c "Print :$1" "$PLIST" 2>/dev/null || true; }
SHORT="$(plist_get CFBundleShortVersionString)"
BUILD="$(plist_get CFBundleVersion)"
BUNDLE_ID="$(plist_get CFBundleIdentifier)"
MIN_OS="$(plist_get LSMinimumSystemVersion)"
PUBKEY="$(plist_get SUPublicEDKey)"
for pair in "CFBundleShortVersionString:$SHORT" "CFBundleVersion:$BUILD" "CFBundleIdentifier:$BUNDLE_ID" "LSMinimumSystemVersion:$MIN_OS" "SUPublicEDKey:$PUBKEY"; do
  [ -n "${pair#*:}" ] || die "Info.plist is missing ${pair%%:*}"
done
[[ "$BUILD" =~ ^[0-9]+$ ]] || die "CFBundleVersion must be numeric, got '$BUILD'"
[[ "$SHORT" =~ ^[0-9A-Za-z.+-]+$ ]] || die "unexpected CFBundleShortVersionString '$SHORT'"
[ "$PUBKEY" = "$CONTRACT_KEY" ] || die "SUPublicEDKey does not match the contract key"

codesign --verify --deep --strict "$BUNDLE" 2>/dev/null || die "codesign --verify --deep --strict failed for $BUNDLE"

WORK="$(mktemp -d)"
cleanup() { [ -n "${WORK:-}" ] && [ -d "$WORK" ] && rm -rf "$WORK"; }
trap cleanup EXIT

# Where the appcast lives. For R2 the current one is fetched from the bucket, not the public address,
# which can be cached. A missing object means a first release; any other error stops here, so old
# items are never dropped.
r2_fetch_appcast() {
  local err="$WORK/r2-get.err"
  if "${WRANGLER[@]}" r2 object get "$R2_BUCKET/$PREFIX/appcast.xml" --file "$APPCAST" --remote >/dev/null 2>"$err"; then
    [ -s "$APPCAST" ] || die "$R2_BUCKET/$PREFIX/appcast.xml is empty"
    xmllint --noout "$APPCAST" 2>/dev/null || die "$R2_BUCKET/$PREFIX/appcast.xml is not well-formed"
    return 0
  fi
  rm -f "$APPCAST"
  if grep -q "The specified key does not exist" "$err"; then
    echo "publish.sh: no $R2_BUCKET/$PREFIX/appcast.xml yet, so this is the first release there"
    return 0
  fi
  cat "$err" >&2
  die "could not fetch $R2_BUCKET/$PREFIX/appcast.xml (log in with: pnpm dlx wrangler login); nothing was published"
}

if [ -n "$DRY_DIR" ]; then
  [ -d "$DRY_DIR" ] || die "dry-run dir does not exist: $DRY_DIR"
  OUT_DIR="$(cd "$DRY_DIR" && pwd)"
  APPCAST="$OUT_DIR/appcast.xml"
elif [ -n "$R2_BUCKET" ]; then
  command -v "${WRANGLER[0]}" >/dev/null || die "${WRANGLER[0]} is required to publish to R2"
  OUT_DIR="$WORK/r2"
  mkdir -p "$OUT_DIR"
  APPCAST="$OUT_DIR/appcast.xml"
  r2_fetch_appcast
else
  OUT_DIR="$REPO_DIR/$APP"
  mkdir -p "$OUT_DIR"
  APPCAST="$OUT_DIR/appcast.xml"
fi

# Build number must exceed every existing item.
if [ -f "$APPCAST" ]; then
  NEWEST="$(grep -o '<sparkle:version>[0-9]*</sparkle:version>' "$APPCAST" | sed 's/<[^>]*>//g' | sort -n | tail -n 1 || true)"
  if [ -n "$NEWEST" ] && [ "$BUILD" -le "$NEWEST" ]; then
    die "build $BUILD is not greater than the newest published build $NEWEST"
  fi
fi

DISPLAY_NAME="$(basename "$BUNDLE" .app)"
NAME="${DISPLAY_NAME// /-}"
ZIP_NAME="$NAME-$SHORT-$BUILD.zip"
# People see the disk image name, so on GitHub it is just the app and its version (each release
# has its own tag). R2 files are cached forever, so there it keeps the build number.
DMG_NAME="$NAME-$SHORT.dmg"
[ -z "$R2_BUCKET" ] || DMG_NAME="$NAME-$SHORT-$BUILD.dmg"
TAG="$APP-v$SHORT-$BUILD"
RELEASE_REPO="$REPO_SLUG" TARGET=""
if [ -n "$OWN_REPO" ]; then
  RELEASE_REPO="$OWN_REPO"
  TAG="v$SHORT"
fi

# A real release in an app's own repo: the tag must be new and the source must be what GitHub has,
# so the tag points at the commit the build came from. Checked before anything is signed or uploaded.
if [ -n "$OWN_REPO" ] && [ -z "$DRY_DIR" ]; then
  command -v gh >/dev/null || die "gh is required"
  SRC="$(cd "$REPO_DIR/.." && pwd)/$APP"
  [ -d "$SRC/.git" ] || die "the $APP checkout is not at $SRC"
  [ -z "$(git -C "$SRC" status --porcelain --untracked-files=no)" ] || die "$SRC has uncommitted changes; commit and push them first"
  git -C "$SRC" fetch -q origin main || die "could not fetch $OWN_REPO"
  TARGET="$(git -C "$SRC" rev-parse HEAD)"
  [ "$TARGET" = "$(git -C "$SRC" rev-parse origin/main)" ] || die "$SRC is not at origin/main; push it first"
  if gh release view "$TAG" --repo "$OWN_REPO" >/dev/null 2>&1 || git -C "$SRC" ls-remote --exit-code --tags origin "refs/tags/$TAG" >/dev/null 2>&1; then
    die "$OWN_REPO already has $TAG; raise VERSION for a new release"
  fi
fi

if [ -n "$R2_BUCKET" ]; then
  # A dry run of an R2 app keeps the real addresses, so the appcast shows what would ship.
  [ -n "$DRY_DIR" ] && FILES="$OUT_DIR" || FILES="$WORK"
  ZIP="$FILES/$ZIP_NAME"
  URL="$R2_BASE/$PREFIX/$ZIP_NAME"
  DMG="$FILES/$DMG_NAME"
  DMG_URL="$R2_BASE/$PREFIX/$DMG_NAME"
elif [ -n "$DRY_DIR" ]; then
  ZIP="$OUT_DIR/$ZIP_NAME"
  URL="http://127.0.0.1:$PORT/$ZIP_NAME"
  DMG="$OUT_DIR/$DMG_NAME"
  DMG_URL="http://127.0.0.1:$PORT/$DMG_NAME"
else
  ZIP="$WORK/$ZIP_NAME"
  URL="https://github.com/$RELEASE_REPO/releases/download/$TAG/$ZIP_NAME"
  DMG="$WORK/$DMG_NAME"
  DMG_URL="https://github.com/$RELEASE_REPO/releases/download/$TAG/$DMG_NAME"
fi

rm -f "$ZIP"
if [ -n "$GIVEN_ZIP" ]; then
  # A zip made after notarization and stapling (tools/notarize.sh); the EdDSA signature below
  # covers exactly this file. It must hold the bundle it was made from.
  [ "$(unzip -Z1 "$GIVEN_ZIP" | head -n 1)" = "$(basename "$BUNDLE")/" ] || die "$GIVEN_ZIP does not start with $(basename "$BUNDLE")/"
  cp "$GIVEN_ZIP" "$ZIP"
else
  ditto -c -k --sequesterRsrc --keepParent "$BUNDLE" "$ZIP"
fi
LENGTH="$(stat -f%z "$ZIP")"
SIG="$("$SIGN_UPDATE" --account "$KEY_ACCOUNT" -p "$ZIP")"
[ -n "$SIG" ] || die "sign_update returned no signature"
PUBDATE="$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')"

# The disk image for first installs, made before the appcast changes so a failed notarization
# publishes nothing. A real publish uploads it only when it is notarized; a dry run keeps it to inspect.
HAVE_DMG=0
DMG_ARGS=(--bundle "$BUNDLE" --out "$DMG")
[ -z "$DRY_DIR" ] || DMG_ARGS+=(--dry-run)
DMG_RC=0
"$SCRIPT_DIR/make-dmg.sh" "${DMG_ARGS[@]}" || DMG_RC=$?
case "$DMG_RC" in
  0) HAVE_DMG=1 ;;
  10) if [ -n "$DRY_DIR" ]; then HAVE_DMG=1; else echo "publish.sh: no disk image for this release (not notarized)"; fi ;;
  *) die "make-dmg.sh failed (exit $DMG_RC)" ;;
esac

# <app>/download/ sends people to the newest disk image, so one link stays good across releases.
# Beta releases leave it alone, and R2 apps have none.
DOWNLOAD_PAGE=""
if [ "$HAVE_DMG" = 1 ] && [ -z "$CHANNEL" ] && [ -z "$R2_BUCKET" ]; then
  DOWNLOAD_PAGE="$OUT_DIR/download/index.html"
  mkdir -p "$OUT_DIR/download"
  python3 -I - "$DOWNLOAD_PAGE" "$DISPLAY_NAME" "$SHORT" "$DMG_URL" <<'PY'
import html, os, sys, tempfile
page, name, short, url = sys.argv[1:5]
n, s, u = (html.escape(x, quote=True) for x in (name, short, url))
doc = f'''<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta http-equiv="refresh" content="0; url={u}">
<title>Download {n}</title>
<style>
:root {{ color-scheme: light dark; }}
body {{ font: 17px/1.5 -apple-system, BlinkMacSystemFont, system-ui, sans-serif; max-width: 34rem; margin: 18vh auto; padding: 0 1.5rem; color: #1d1d1f; background: #fff; }}
a {{ color: #0066cc; }}
@media (prefers-color-scheme: dark) {{ body {{ color: #f5f5f7; background: #1d1d1f; }} a {{ color: #4da3ff; }} }}
</style>
</head>
<body>
<p>Downloading {n} {s}. If nothing happens, <a href="{u}">download it here</a>.</p>
<p>Open the disk image and drag {n} to Applications.</p>
</body>
</html>
'''
fd, tmp = tempfile.mkstemp(dir=os.path.dirname(page), prefix='.download.')
with os.fdopen(fd, 'w', encoding='utf-8') as f:
    f.write(doc)
os.replace(tmp, page)
PY
fi

# Write or update the appcast.
if [ -n "$R2_BUCKET" ]; then FEED_URL="$R2_BASE/$PREFIX/appcast.xml"; else FEED_URL="$PAGES_BASE/$APP/appcast.xml"; fi
python3 -I - "$APPCAST" "$NOTES" "$APP" "$FEED_URL" "$SHORT" "$BUILD" "$MIN_OS" "$URL" "$LENGTH" "$SIG" "$PUBDATE" "$CHANNEL" <<'PY'
import html, os, re, sys, tempfile
appcast, notes, app, feed, short, build, minos, url, length, sig, pubdate, channel = sys.argv[1:13]

def inline(s):
    s = html.escape(s, quote=False)
    s = re.sub(r'`([^`]+)`', r'<code>\1</code>', s)
    s = re.sub(r'\*\*([^*]+)\*\*', r'<strong>\1</strong>', s)
    s = re.sub(r'(?<![\w*])\*([^*\n]+)\*(?![\w*])', r'<em>\1</em>', s)
    return s

def render(md):
    out, para, in_list = [], [], False
    def flush():
        nonlocal para
        if para:
            out.append('<p>' + inline(' '.join(para)) + '</p>')
            para = []
    def close():
        nonlocal in_list
        if in_list:
            out.append('</ul>')
            in_list = False
    for line in md.splitlines():
        t = line.strip()
        m = re.match(r'^(#{1,6})\s+(.*)$', t)
        b = re.match(r'^[-*+]\s+(.*)$', t)
        if not t:
            flush(); close()
        elif m:
            flush(); close()
            n = min(len(m.group(1)) + 1, 6)
            out.append('<h%d>%s</h%d>' % (n, inline(m.group(2)), n))
        elif b:
            flush()
            if not in_list:
                out.append('<ul>'); in_list = True
            out.append('<li>' + inline(b.group(1)) + '</li>')
        else:
            close(); para.append(t)
    flush(); close()
    return '\n'.join(out)

desc = ''
if notes:
    with open(notes, encoding='utf-8') as f:
        body = render(f.read()).replace(']]>', ']]]]><![CDATA[>')
    if body:
        desc = '      <description><![CDATA[\n%s\n]]></description>\n' % body

esc = lambda s: html.escape(s, quote=True)
item = (
    '    <item>\n'
    '      <title>Version %s</title>\n'
    '      <pubDate>%s</pubDate>\n'
    '      <sparkle:version>%s</sparkle:version>\n'
    '      <sparkle:shortVersionString>%s</sparkle:shortVersionString>\n'
    '      <sparkle:minimumSystemVersion>%s</sparkle:minimumSystemVersion>\n'
    '%s'
    '%s'
    '      <enclosure url="%s" length="%s" type="application/octet-stream" sparkle:edSignature="%s"/>\n'
    '    </item>\n'
) % (esc(short), pubdate, esc(build), esc(short), esc(minos),
       ('      <sparkle:channel>%s</sparkle:channel>\n' % esc(channel)) if channel else '', desc, esc(url), esc(length), esc(sig))

old_items = []
if os.path.exists(appcast):
    with open(appcast, encoding='utf-8') as f:
        text = f.read()
    old_items = [m.group(0) + '\n' for m in re.finditer(r'    <item>.*?</item>', text, re.S)]
    # Sort existing items newest first by build number.
    def key(it):
        m = re.search(r'<sparkle:version>(\d+)</sparkle:version>', it)
        return -int(m.group(1)) if m else 0
    old_items.sort(key=key)

doc = (
    '<?xml version="1.0" encoding="utf-8"?>\n'
    '<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" xmlns:dc="http://purl.org/dc/elements/1.1/">\n'
    '  <channel>\n'
    '    <title>%s</title>\n'
    '    <link>%s</link>\n'
    '    <description>Updates for %s</description>\n'
    '    <language>en</language>\n'
) % (esc(app), esc(feed), esc(app)) + item + ''.join(old_items) + '  </channel>\n</rss>\n'

d = os.path.dirname(appcast)
fd, tmp = tempfile.mkstemp(dir=d, prefix='.appcast.')
with os.fdopen(fd, 'w', encoding='utf-8') as f:
    f.write(doc)
os.replace(tmp, appcast)
PY
xmllint --noout "$APPCAST" || die "generated appcast is not well-formed"

if [ -n "$DRY_DIR" ]; then
  echo "dry-run: $APP $SHORT ($BUILD) release=$RELEASE_REPO@$TAG zip=$ZIP appcast=$APPCAST url=$URL length=$LENGTH dmg=$([ "$HAVE_DMG" = 1 ] && echo "$DMG" || echo none) download=${DOWNLOAD_PAGE:-unchanged}"
  exit 0
fi

# Real mode, R2: the zip, then the disk image, then the appcast, so the feed never names a file
# that isn't there yet. File names carry the build number, so they never change once uploaded.
r2_put() { # file key content-type cache-control
  "${WRANGLER[@]}" r2 object put "$R2_BUCKET/$PREFIX/$2" --file "$1" --content-type "$3" --cache-control "$4" --remote >/dev/null \
    || die "uploading $R2_BUCKET/$PREFIX/$2 failed; the appcast was not changed"
}
if [ -n "$R2_BUCKET" ]; then
  r2_put "$ZIP" "$ZIP_NAME" application/zip "public, max-age=31536000, immutable"
  [ "$HAVE_DMG" = 0 ] || r2_put "$DMG" "$DMG_NAME" application/x-apple-diskimage "public, max-age=31536000, immutable"
  r2_put "$APPCAST" appcast.xml "application/xml; charset=utf-8" "no-cache"
  echo "published: $APP $SHORT ($BUILD) to r2://$R2_BUCKET/$PREFIX feed=$FEED_URL length=$LENGTH dmg=$([ "$HAVE_DMG" = 1 ] && echo "$DMG_URL" || echo none)"
  exit 0
fi

# Real mode, GitHub.
command -v gh >/dev/null || die "gh is required"
ASSETS=("$ZIP")
[ "$HAVE_DMG" = 0 ] || ASSETS+=("$DMG")
if [ -n "$OWN_REPO" ]; then
  NOTES_FILE="$WORK/release-notes.md"
  if [ -n "$NOTES" ]; then cp "$NOTES" "$NOTES_FILE"; else printf '%s %s\n' "$DISPLAY_NAME" "$SHORT" >"$NOTES_FILE"; fi
  printf '\nBuild %s. Download %s, open it and drag %s into Applications. It updates itself after that.\n' "$BUILD" "$DMG_NAME" "$DISPLAY_NAME" >>"$NOTES_FILE"
  gh release create "$TAG" "${ASSETS[@]}" --repo "$RELEASE_REPO" --target "$TARGET" --title "$DISPLAY_NAME $SHORT" --notes-file "$NOTES_FILE"
else
  gh release create "$TAG" "${ASSETS[@]}" --repo "$REPO_SLUG" --title "$APP $SHORT ($BUILD)" --notes "${APP} ${SHORT} (build ${BUILD})"
fi
PATHS=("$APP/appcast.xml")
[ -z "$DOWNLOAD_PAGE" ] || PATHS+=("$APP/download/index.html")
git -C "$REPO_DIR" add "${PATHS[@]}"
git -C "$REPO_DIR" commit -m "$APP $SHORT ($BUILD)" -- "${PATHS[@]}"
git -C "$REPO_DIR" push origin main
echo "published: $APP $SHORT ($BUILD) release=$RELEASE_REPO@$TAG feed=$FEED_URL length=$LENGTH${DOWNLOAD_PAGE:+ download=$PAGES_BASE/$APP/download/}"
