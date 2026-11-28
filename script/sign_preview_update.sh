#!/usr/bin/env bash
set -euo pipefail

if [[ $# != 1 || ! -f "$1" ]]; then
  printf 'Usage: SPARKLE_BIN_DIR=/path/to/sparkle/bin bash %s NotchFinder-VERSION-arm64.dmg\n' "$0" >&2
  exit 2
fi

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOOLS="${SPARKLE_BIN_DIR:?Set SPARKLE_BIN_DIR to the bin directory in the official Sparkle distribution}"
ACCOUNT=local.notchfinder.preview
DMG="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
NAME="${DMG##*/}"
if [[ ! "$NAME" =~ ^NotchFinder-([0-9]+\.[0-9]+\.[0-9]+)-(arm64|universal)\.dmg$ ]]; then
  printf 'Use the GitHub release asset name NotchFinder-VERSION-arm64.dmg or NotchFinder-VERSION-universal.dmg.\n' >&2
  exit 2
fi
VERSION="${BASH_REMATCH[1]}"
RELEASES=https://github.com/chenghsj/NotchFinder/releases
DOWNLOAD="$RELEASES/download/v$VERSION"

PUBLIC_KEY="$("$TOOLS/generate_keys" -p --account "$ACCOUNT")"
if [[ "$PUBLIC_KEY" != "$(cat "$PROJECT_DIR/updates/preview-public-key.txt")" ]]; then
  printf 'The Keychain key does not match the public key embedded in Notch Finder.\n' >&2
  exit 1
fi

STAGE="$(mktemp -d "${TMPDIR:-/tmp}/notchfinder-sign.XXXXXXXX")"
MOUNT="$STAGE/mount"
mounted=false
cleanup() {
  if [[ "$mounted" == true ]]; then
    /usr/bin/hdiutil detach "$MOUNT" >/dev/null || return 1
  fi
  rm -rf -- "$STAGE"
}
trap cleanup EXIT
mkdir "$STAGE/archives" "$MOUNT"
cp "$DMG" "$STAGE/archives/$NAME"

# Compare with GitHub main, even when the checkout already contains an unpublished feed.
PUBLISHED="$STAGE/published.xml"
/usr/bin/curl --fail --silent --show-error --location --retry 2 --max-time 60 \
  -H 'Accept: application/vnd.github.raw+json' \
  'https://api.github.com/repos/chenghsj/NotchFinder/contents/updates/preview.xml?ref=main' -o "$PUBLISHED"
"$TOOLS/sign_update" --account "$ACCOUNT" --verify "$PUBLISHED"

/usr/bin/hdiutil attach -readonly -nobrowse -mountpoint "$MOUNT" "$STAGE/archives/$NAME" >/dev/null
mounted=true
BUILD="$(/usr/bin/plutil -extract CFBundleVersion raw -expect string -o - "$MOUNT/NotchFinder.app/Contents/Info.plist")"
/usr/bin/hdiutil detach "$MOUNT" >/dev/null
mounted=false

/usr/bin/python3 - "$PUBLISHED" "$BUILD" <<'PY'
import re
import sys
import xml.etree.ElementTree as ET

def build_number(value):
    if not re.fullmatch(r"[1-9][0-9]*", value):
        sys.exit(f"Expected a positive integer build number, got {value!r}.")
    return int(value)

items = ET.parse(sys.argv[1]).findall("./channel/item")
if not items:
    sys.exit("The published update feed contains no builds.")
version = "{http://www.andymatuschak.org/xml-namespaces/sparkle}version"
published = max(build_number(item.findtext(version, "")) for item in items)
candidate = build_number(sys.argv[2])
if candidate <= published:
    sys.exit(f"Candidate build {candidate} must be higher than published build {published}.")
PY

"$TOOLS/generate_appcast" --account "$ACCOUNT" --maximum-deltas 0 \
  --download-url-prefix "$DOWNLOAD/" --link "$RELEASES/tag/v$VERSION" \
  -o "$STAGE/preview.xml" "$STAGE/archives"

FEED="$STAGE/preview.xml"
if [[ "$(/usr/bin/xmllint --nonet --xpath 'string(//enclosure/@url)' "$FEED")" != "$DOWNLOAD/$NAME" ||
      "$(/usr/bin/xmllint --nonet --xpath 'string(//*[local-name()="shortVersionString"])' "$FEED")" != "$VERSION" ||
      "$(/usr/bin/xmllint --nonet --xpath 'string(//*[local-name()="version"])' "$FEED")" != "$BUILD" ]]; then
  printf 'The generated feed must match the release filename and the build inside the DMG.\n' >&2
  exit 1
fi
SIGNATURE="$(/usr/bin/xmllint --nonet --xpath 'string(//enclosure/@*[local-name()="edSignature"])' "$FEED")"
"$TOOLS/sign_update" --account "$ACCOUNT" --verify "$STAGE/archives/$NAME" "$SIGNATURE"
"$TOOLS/sign_update" --account "$ACCOUNT" --verify "$FEED"

printf '%s\n' "$SIGNATURE" > "$DMG.sig"
INSTALL_DIR="$(dirname "$DMG")/${NAME%.dmg}"
mkdir -p "$INSTALL_DIR"
INSTALL_DMG="$INSTALL_DIR/NotchFinder-arm64.dmg"
cp "$STAGE/archives/$NAME" "$INSTALL_DMG"
cp "$FEED" "$PROJECT_DIR/updates/preview.xml"
printf 'Upload to the v%s draft release:\n' "$VERSION"
printf 'gh release upload v%s --repo chenghsj/NotchFinder %q %q %q\n' "$VERSION" "$DMG" "$DMG.sig" "$INSTALL_DMG"
