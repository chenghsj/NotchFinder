#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="NotchFinder"
DISPLAY_NAME="Notch Finder"
BUNDLE_ID="local.notchfinder.app"
MACOS_MIN_VERSION="14.0" # Keep in sync with Package.swift.
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${NOTCH_FINDER_BUILD_DIR:-$PROJECT_DIR}"
CONFIGURATION="${NOTCH_FINDER_BUILD_CONFIGURATION:-debug}"
SIGNING_IDENTITY="${NOTCH_FINDER_SIGNING_IDENTITY:-}"
APP_VERSION="${NOTCH_FINDER_VERSION:-0.1.2}"
BUILD_NUMBER="${NOTCH_FINDER_BUILD_NUMBER:-3}"
UPDATE_FEED="https://raw.githubusercontent.com/chenghsj/NotchFinder/main/updates/preview.xml"
UPDATE_PUBLIC_KEY="$(cat "$PROJECT_DIR/updates/preview-public-key.txt")"
APP_BUNDLE="$BUILD_DIR/dist/$APP_NAME.app"
TEST_DIR=""
TEST_LAUNCH_ATTEMPTED=false
TEST_COMMAND_PID=""
TEST_SETTINGS=false

if [[ ! "$APP_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ || ! "$BUILD_NUMBER" =~ ^[1-9][0-9]*$ ]]; then
  printf 'Set NOTCH_FINDER_VERSION to three numeric components and NOTCH_FINDER_BUILD_NUMBER to a positive integer.\n' >&2
  exit 2
fi

usage() {
  printf 'Usage: %s [run|--build|--debug|--logs|--telemetry|--verify]\n' "$0" >&2
  printf '       %s --test [--settings] [-- command [args...]]\n' "$0" >&2
  exit 2
}

test_app() {
  /usr/bin/osascript -l JavaScript "$PROJECT_DIR/script/test_app.js" "$1" "$BUNDLE_ID" "$APP_BUNDLE"
}

cleanup_test_app() {
  local status=$?
  trap - EXIT
  trap '' HUP INT TERM

  if [[ -n "$TEST_COMMAND_PID" ]]; then
    kill -TERM "$TEST_COMMAND_PID" 2>/dev/null || true
  fi
  if [[ "$TEST_LAUNCH_ATTEMPTED" == true ]]; then
    if ! test_app quit; then
      printf 'Could not close the test app at %s\n' "$APP_BUNDLE" >&2
      exit 1
    fi
    /usr/bin/defaults delete "$BUNDLE_ID" >/dev/null 2>&1 || true
  fi
  if [[ -n "$TEST_DIR" ]]; then
    rm -rf -- "$TEST_DIR"
  fi
  exit "$status"
}

if (( $# > 0 )); then shift; fi

case "$MODE" in
  --test)
    if [[ "${1:-}" == "--settings" ]]; then
      TEST_SETTINGS=true
      shift
    fi
    if (( $# > 0 )); then
      [[ "$1" == "--" && $# -gt 1 ]] || usage
      shift
    fi
    ;;
  run|--build|--debug|--logs|--telemetry|--verify) ;;
  *) usage ;;
esac

case "$MODE" in
  --test|--verify)
    trap cleanup_test_app EXIT
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM
    TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/notchfinder-test.XXXXXXXX")"
    TEST_DIR="$(cd "$TEST_DIR" && pwd -P)"
    BUNDLE_ID="local.notchfinder.test.${TEST_DIR##*.}"
    DISPLAY_NAME="Notch Finder Test"
    APP_BUNDLE="$TEST_DIR/$DISPLAY_NAME.app"
    ;;
  --build) ;;
  *) pkill -x "$APP_NAME" >/dev/null 2>&1 || true ;;
esac
APP_BINARY="$APP_BUNDLE/Contents/MacOS/$APP_NAME"

CACHE_DIR="$BUILD_DIR/.build/ModuleCache"
mkdir -p "$CACHE_DIR"
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-$CACHE_DIR}"
export SWIFTPM_MODULECACHE_OVERRIDE="${SWIFTPM_MODULECACHE_OVERRIDE:-$CACHE_DIR}"

SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"
SDK_VERSION="$(xcrun --sdk macosx --show-sdk-version)"
# Record the actual linked SDK so AppKit adopts current system control styles.
SWIFT_BUILD=(swift build --package-path "$PROJECT_DIR" --scratch-path "$BUILD_DIR/.build"
  --configuration "$CONFIGURATION" --sdk "$SDK_PATH"
  -Xlinker -platform_version -Xlinker macos -Xlinker "$MACOS_MIN_VERSION" -Xlinker "$SDK_VERSION")
if [[ "$CONFIGURATION" == "release" ]]; then
  SWIFT_BUILD+=(-debug-info-format none)
fi
if [[ "${NOTCH_FINDER_DISABLE_SWIFTPM_SANDBOX:-0}" == "1" ]]; then
  SWIFT_BUILD+=(--disable-sandbox)
fi
"${SWIFT_BUILD[@]}"
BIN_DIR="$("${SWIFT_BUILD[@]}" --show-bin-path)"

mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Frameworks"
install -m 755 "$BIN_DIR/$APP_NAME" "$APP_BINARY"
/usr/bin/ditto "$PROJECT_DIR/Resources" "$APP_BUNDLE/Contents/Resources"
SPARKLE_FRAMEWORK="$APP_BUNDLE/Contents/Frameworks/Sparkle.framework"
rm -rf -- "$SPARKLE_FRAMEWORK"
/usr/bin/ditto "$BIN_DIR/Sparkle.framework" "$SPARKLE_FRAMEWORK"

cat > "$APP_BUNDLE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>zh-Hant</string>
  <key>CFBundleDisplayName</key><string>$DISPLAY_NAME</string>
  <key>CFBundleExecutable</key><string>$APP_NAME</string>
  <key>CFBundleIconFile</key><string>NotchFinder</string>
  <key>CFBundleIconName</key><string>NotchFinder</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleName</key><string>$DISPLAY_NAME</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$APP_VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
  <key>LSMinimumSystemVersion</key><string>$MACOS_MIN_VERSION</string>
  <key>LSUIElement</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>SUFeedURL</key><string>$UPDATE_FEED</string>
  <key>SUPublicEDKey</key><string>$UPDATE_PUBLIC_KEY</string>
  <key>SUVerifyUpdateBeforeExtraction</key><true/>
  <key>SURequireSignedFeed</key><true/>
  <key>SUSignedFeedFailureExpirationInterval</key><integer>0</integer>
  <key>SUEnableAutomaticChecks</key><false/>
  <key>SUAllowsAutomaticUpdates</key><false/>
  <key>UTExportedTypeDeclarations</key>
  <array>
    <dict>
      <key>UTTypeIdentifier</key><string>local.notchfinder.sidebar-location</string>
      <key>UTTypeDescription</key><string>Notch Finder Sidebar Location</string>
      <key>UTTypeConformsTo</key><array><string>public.data</string></array>
    </dict>
  </array>
</dict>
</plist>
PLIST

if [[ -z "$SIGNING_IDENTITY" ]]; then
  SIGNING_IDENTITY="$(/usr/bin/security find-identity -v -p codesigning 2>/dev/null |
    /usr/bin/awk '/"Apple Development:/ {identity = $2; count++} END {if (count == 1) print identity}')"
fi
SIGN=(/usr/bin/codesign --force --sign "${SIGNING_IDENTITY:--}" --timestamp=none)
SPARKLE_VERSION="$SPARKLE_FRAMEWORK/Versions/Current"
for component in "$SPARKLE_VERSION/Autoupdate" "$SPARKLE_VERSION/Updater.app" "$SPARKLE_VERSION"/XPCServices/*.xpc; do
  [[ -e "$component" ]] || continue
  "${SIGN[@]}" --preserve-metadata=identifier,entitlements "$component"
done
"${SIGN[@]}" "$SPARKLE_FRAMEWORK"
"${SIGN[@]}" "$APP_BUNDLE"

open_app() {
  /usr/bin/open -n "$APP_BUNDLE"
}

run_test_app() {
  local open_args=(-n --env "NOTCH_FINDER_TEST_DATA_DIR=$TEST_DIR/data" "$APP_BUNDLE")
  if [[ "$TEST_SETTINGS" == true ]]; then
    open_args+=(--args --settings)
  fi

  TEST_LAUNCH_ATTEMPTED=true
  /usr/bin/open "${open_args[@]}"
  NOTCH_FINDER_TEST_APP_PID="$(test_app pid)"

  if [[ "$MODE" == "--verify" ]]; then
    printf '%s\n' "$NOTCH_FINDER_TEST_APP_PID"
  elif (( $# > 0 )); then
    export NOTCH_FINDER_TEST_APP_PID
    export NOTCH_FINDER_TEST_APP_BUNDLE="$APP_BUNDLE"
    local status=0
    "$@" <&3 3<&- &
    TEST_COMMAND_PID=$!
    wait "$TEST_COMMAND_PID" || status=$?
    TEST_COMMAND_PID=""
    return "$status"
  else
    printf 'Press Enter to close Notch Finder Test and finish testing.\n' >&2
    read -r || true
  fi
}

case "$MODE" in
  --build) printf '%s\n' "$APP_BUNDLE" ;;
  run) open_app ;;
  --debug) lldb -- "$APP_BINARY" ;;
  --logs)
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry)
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --test|--verify) run_test_app "$@" 3<&0 ;;
esac
