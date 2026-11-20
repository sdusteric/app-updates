#!/bin/bash
# Publish Kalos's block lists between app releases. See CONTRACT.md, "Kalos block lists".
#
#   publish-blocklists.sh                       build the lists, check, sign with the Keychain key, upload to R2
#   publish-blocklists.sh --dry-run <dir>       the same into <dir>, signed with a throwaway key, nothing uploaded
#   publish-blocklists.sh --make-key            make the signing key once (Keychain asks); prints the public key
#
# --from <folder> uses lists already built (plain chunks, manifest.json, cosmetic.json, scriptlets.json, as
# ../pane/resources/blocklists holds them) instead of running ../pane/scripts/make-blocklists.sh, which fetches the
# upstream lists. --previous <manifest.json> compares against that manifest instead of the published one.
set -euo pipefail

R2_BUCKET="kalos-updates"
R2_PREFIX="kalos/blocklists/v1"
R2_BASE="${KALOS_UPDATES_BASE:-https://updates.kalosbrowser.com}"
# The command that talks to R2. Tests put a fake here.
read -r -a WRANGLER <<<"${PUBLISH_WRANGLER:-pnpm dlx wrangler}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PANE_DIR="$(cd "$SCRIPT_DIR/../../pane" 2>/dev/null && pwd || true)"
KEY_TOOL=(xcrun swift "$SCRIPT_DIR/blocklist-key.swift")

usage() {
  echo "usage: publish-blocklists.sh [--dry-run <dir>] [--from <lists folder>] [--previous <manifest.json>] | --make-key" >&2
  exit 2
}
die() { echo "publish-blocklists.sh: error: $*" >&2; exit 1; }

DRY_DIR="" FROM="" PREVIOUS="" MAKE_KEY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) [ $# -ge 2 ] || usage; DRY_DIR="$2"; shift 2 ;;
    --from) [ $# -ge 2 ] || usage; FROM="$2"; shift 2 ;;
    --previous) [ $# -ge 2 ] || usage; PREVIOUS="$2"; shift 2 ;;
    --make-key) MAKE_KEY=1; shift ;;
    *) usage ;;
  esac
done

if [ "$MAKE_KEY" = 1 ]; then
  [ -z "$DRY_DIR$FROM$PREVIOUS" ] || usage
  echo "publish-blocklists.sh: making the block list signing key in the login Keychain (it is never printed or exported)"
  PUBLIC="$("${KEY_TOOL[@]}" make-key)"
  echo "Public key, for BlockListKey.current in pane/Sources/PaneCore/BlockListKey.swift:"
  echo "  $PUBLIC"
  exit 0
fi

WORK="$(mktemp -d)"
cleanup() { [ -n "${WORK:-}" ] && [ -d "$WORK" ] && rm -rf "$WORK"; }
trap cleanup EXIT

if [ -n "$DRY_DIR" ]; then
  [ -d "$DRY_DIR" ] || die "dry-run dir does not exist: $DRY_DIR"
  OUT="$(cd "$DRY_DIR" && pwd)"
  [ -z "$(ls -A "$OUT")" ] || die "dry-run dir is not empty: $OUT"
else
  command -v "${WRANGLER[0]}" >/dev/null || die "${WRANGLER[0]} is required to publish to R2"
  OUT="$WORK/out"
  mkdir -p "$OUT"
fi

# 1. The lists.
if [ -n "$FROM" ]; then
  [ -f "$FROM/manifest.json" ] || die "no manifest.json in $FROM"
  LISTS="$(cd "$FROM" && pwd)"
else
  [ -n "$PANE_DIR" ] && [ -x "$PANE_DIR/scripts/make-blocklists.sh" ] || die "../pane/scripts/make-blocklists.sh not found"
  LISTS="$WORK/lists"
  PANE_BLOCKLISTS_OUT="$LISTS" "$PANE_DIR/scripts/make-blocklists.sh"
fi

# 2. What it is compared with: the published manifest, or the one given.
PREV="$WORK/previous.json"
if [ -n "$PREVIOUS" ]; then
  cp "$PREVIOUS" "$PREV"
elif [ -n "$DRY_DIR" ]; then
  # A dry run reads nothing from the network: with no --previous it compares with the lists the app ships.
  [ -n "$PANE_DIR" ] && cp "$PANE_DIR/resources/blocklists/manifest.json" "$PREV" || echo '{"chunks":[],"generated":""}' > "$PREV"
else
  curl -fsS "$R2_BASE/$R2_PREFIX/manifest.json" -o "$PREV" 2>/dev/null \
    || { echo "publish-blocklists.sh: nothing published yet, so this is the first update"; echo '{"chunks":[],"generated":""}' > "$PREV"; }
fi

# 3. Compress every chunk and both indexes, then write the manifest with a hash and size for each served file. The
# checks refuse a build that looks wrong before anything is signed.
for f in "$LISTS"/*-[0-9]*.json cosmetic.json scriptlets.json; do
  [ -f "$f" ] || f="$LISTS/$f"
  [ -f "$f" ] || die "missing $(basename "$f") in $LISTS"
  compression_tool -encode -a lzfse -i "$f" -o "$OUT/$(basename "$f").lzfse"
done
python3 -I - "$LISTS/manifest.json" "$PREV" "$OUT" <<'PY'
import datetime, hashlib, json, os, re, sys
built, previous, out = json.load(open(sys.argv[1])), json.load(open(sys.argv[2])), sys.argv[3]
def fail(message):
    sys.exit(f"publish-blocklists.sh: refused: {message}")
def stamp(text):
    try:
        return datetime.datetime.strptime(text, "%Y-%m-%dT%H:%M:%SZ")
    except (TypeError, ValueError):
        return None
for chunk in built["chunks"]:
    if not re.fullmatch(r"[a-z][a-z0-9-]*\.json", chunk["file"]) or chunk["file"] in ("cosmetic.json", "scriptlets.json"):
        fail(f"{chunk['file']} is not a chunk name the app accepts")
    if chunk["rules"] > 40000:
        fail(f"{chunk['file']} has {chunk['rules']} rules; WebKit blocks nothing past about 40,000 in one list")
def per_list(manifest):
    totals = {}
    for chunk in manifest.get("chunks", []):
        name = re.sub(r"-\d+\.json$", "", chunk["file"])
        totals[name] = totals.get(name, 0) + chunk["rules"]
    return totals
now, before = per_list(built), per_list(previous)
for name, rules in before.items():
    if now.get(name, 0) < rules * 0.8:
        fail(f"{name} has {now.get(name, 0)} rules, under 80% of the {rules} it had (an upstream list came back short)")
new, old = stamp(built["generated"]), stamp(previous.get("generated", ""))
if new is None:
    fail(f"the build time {built['generated']!r} is not a UTC time")
if old is not None and new <= old:
    fail(f"this build ({built['generated']}) is not newer than the one it is compared with ({previous['generated']})")
files = {}
for name in sorted(os.listdir(out)):
    data = open(os.path.join(out, name), "rb").read()
    files[name] = {"sha256": hashlib.sha256(data).hexdigest(), "size": len(data)}
for chunk in built["chunks"]:
    if chunk["file"] + ".lzfse" not in files:
        fail(f"{chunk['file']} is in the manifest but not in the lists folder")
manifest = {"chunks": built["chunks"], "files": files, "format": 1, "generated": built["generated"]}
with open(os.path.join(out, "manifest.json"), "w") as handle:
    json.dump(manifest, handle, indent=2, sort_keys=True)
print(f"{len(built['chunks'])} chunks, {sum(c['rules'] for c in built['chunks'])} rules, built {built['generated']}; "
      f"{sum(f['size'] for f in files.values())} bytes served")
PY

# 4. Sign the manifest's exact bytes.
if [ -n "$DRY_DIR" ]; then
  # Never the Keychain key: a key made for this run, dropped after. Its public half is left beside the signature.
  "${KEY_TOOL[@]}" sign-throwaway "$OUT/manifest.json" "$OUT/manifest.json.sig" "$OUT/throwaway-public-key.txt"
  "${KEY_TOOL[@]}" verify "$OUT/manifest.json" "$OUT/manifest.json.sig" "$(cat "$OUT/throwaway-public-key.txt")" >/dev/null
  echo "publish-blocklists.sh: dry run in $OUT, signed with a throwaway key; nothing was uploaded"
  exit 0
fi
"${KEY_TOOL[@]}" sign "$OUT/manifest.json" "$OUT/manifest.json.sig"
"${KEY_TOOL[@]}" verify "$OUT/manifest.json" "$OUT/manifest.json.sig" "$("${KEY_TOOL[@]}" public-key)" >/dev/null

# 5. Upload: every file first, the signature next, the manifest last, so an app never reads a manifest whose files
# are not there yet. Names stay the same from day to day, so nothing is cached.
put() {
  "${WRANGLER[@]}" r2 object put "$R2_BUCKET/$R2_PREFIX/$1" --file "$OUT/$1" --content-type "$2" --cache-control "no-cache" --remote >/dev/null \
    || die "upload of $1 failed; until the next publish, apps that check drop the update whole and keep the lists they have"
}
for f in "$OUT"/*.lzfse; do put "$(basename "$f")" application/octet-stream; done
put manifest.json.sig application/octet-stream
put manifest.json application/json
echo "publish-blocklists.sh: published to $R2_BASE/$R2_PREFIX/"
