#!/bin/bash
# Publish a signed Sparkle update for one app. See README.md and CONTRACT.md.
set -euo pipefail

REPO_SLUG="sdusteric/app-updates"
KEY_ACCOUNT="sdusteric-apps"
CONTRACT_KEY="PMaW+8sZRzOkfIwy1KBGk0CHTVoN49FE9o8gUlNGdZc="
PAGES_BASE="https://sdusteric.github.io/app-updates"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SIGN_UPDATE="$REPO_DIR/vendor/Sparkle-2.10.0/bin/sign_update"

usage() {
  echo "usage: publish.sh --app <app> --bundle <path/App.app> [--notes <file.md>] [--dry-run <dir>] [--port <n>] [--zip <file.zip>] [--channel <name>]" >&2
  exit 2
}
die() { echo "publish.sh: error: $*" >&2; exit 1; }

APP="" BUNDLE="" NOTES="" DRY_DIR="" PORT="8765" GIVEN_ZIP="" CHANNEL=""
while [ $# -gt 0 ]; do
  case "$1" in
    --app) [ $# -ge 2 ] || usage; APP="$2"; shift 2 ;;
    --bundle) [ $# -ge 2 ] || usage; BUNDLE="$2"; shift 2 ;;
    --notes) [ $# -ge 2 ] || usage; NOTES="$2"; shift 2 ;;
    --dry-run) [ $# -ge 2 ] || usage; DRY_DIR="$2"; shift 2 ;;
    --port) [ $# -ge 2 ] || usage; PORT="$2"; shift 2 ;;
    --zip) [ $# -ge 2 ] || usage; GIVEN_ZIP="$2"; shift 2 ;;
    --channel) [ $# -ge 2 ] || usage; CHANNEL="$2"; shift 2 ;;
    *) usage ;;
  esac
done
[ -n "$APP" ] && [ -n "$BUNDLE" ] || usage
[[ "$APP" =~ ^[a-z][a-z0-9-]*$ ]] || die "--app must be lowercase letters, digits and dashes"
[[ "$PORT" =~ ^[0-9]+$ ]] || die "--port must be a number"
# Sparkle offers an item with <sparkle:channel> only to apps that allow that channel; with none, everyone gets it.
[ -z "$CHANNEL" ] || [[ "$CHANNEL" =~ ^[a-z]+$ ]] || die "--channel must be lowercase letters"
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

# Where the appcast lives.
if [ -n "$DRY_DIR" ]; then
  [ -d "$DRY_DIR" ] || die "dry-run dir does not exist: $DRY_DIR"
  OUT_DIR="$(cd "$DRY_DIR" && pwd)"
  APPCAST="$OUT_DIR/appcast.xml"
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

NAME="$(basename "$BUNDLE" .app)"
NAME="${NAME// /-}"
ZIP_NAME="$NAME-$SHORT-$BUILD.zip"
TAG="$APP-v$SHORT-$BUILD"

WORK="$(mktemp -d)"
cleanup() { [ -n "${WORK:-}" ] && [ -d "$WORK" ] && rm -rf "$WORK"; }
trap cleanup EXIT

if [ -n "$DRY_DIR" ]; then
  ZIP="$OUT_DIR/$ZIP_NAME"
  URL="http://127.0.0.1:$PORT/$ZIP_NAME"
else
  ZIP="$WORK/$ZIP_NAME"
  URL="https://github.com/$REPO_SLUG/releases/download/$TAG/$ZIP_NAME"
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

# Write or update the appcast.
FEED_URL="$PAGES_BASE/$APP/appcast.xml"
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
  echo "dry-run: $APP $SHORT ($BUILD) zip=$ZIP appcast=$APPCAST url=$URL length=$LENGTH"
  exit 0
fi

# Real mode.
command -v gh >/dev/null || die "gh is required"
gh release create "$TAG" "$ZIP" --repo "$REPO_SLUG" --title "$APP $SHORT ($BUILD)" --notes "${APP} ${SHORT} (build ${BUILD})"
git -C "$REPO_DIR" add "$APP/appcast.xml"
git -C "$REPO_DIR" commit -m "$APP $SHORT ($BUILD)" -- "$APP/appcast.xml"
git -C "$REPO_DIR" push origin main
echo "published: $APP $SHORT ($BUILD) release=$TAG feed=$FEED_URL length=$LENGTH"
