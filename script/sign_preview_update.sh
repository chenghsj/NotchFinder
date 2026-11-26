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
trap 'rm -rf -- "$STAGE"' EXIT
mkdir "$STAGE/archives"
cp "$DMG" "$STAGE/archives/$NAME"

"$TOOLS/generate_appcast" --account "$ACCOUNT" --maximum-deltas 0 \
  --download-url-prefix "$DOWNLOAD/" --link "$RELEASES/tag/v$VERSION" \
  -o "$STAGE/preview.xml" "$STAGE/archives"

FEED="$STAGE/preview.xml"
if [[ "$(/usr/bin/xmllint --nonet --xpath 'string(//enclosure/@url)' "$FEED")" != "$DOWNLOAD/$NAME" ||
      "$(/usr/bin/xmllint --nonet --xpath 'string(//*[local-name()="shortVersionString"])' "$FEED")" != "$VERSION" ]]; then
  printf 'The app inside the DMG must use the version in the release filename.\n' >&2
  exit 1
fi
SIGNATURE="$(/usr/bin/xmllint --nonet --xpath 'string(//enclosure/@*[local-name()="edSignature"])' "$FEED")"
"$TOOLS/sign_update" --account "$ACCOUNT" --verify "$STAGE/archives/$NAME" "$SIGNATURE"
"$TOOLS/sign_update" --account "$ACCOUNT" --verify "$FEED"

printf '%s\n' "$SIGNATURE" > "$DMG.sig"
cp "$FEED" "$PROJECT_DIR/updates/preview.xml"
printf 'Upload %s and %s to v%s, then publish updates/preview.xml on main.\n' "$NAME" "$NAME.sig" "$VERSION"
