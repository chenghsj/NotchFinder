#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="NotchFinder"
BUNDLE_ID="local.notchfinder.app"
MACOS_MIN_VERSION="14.0" # Keep in sync with Package.swift.
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${NOTCH_FINDER_BUILD_DIR:-$PROJECT_DIR}"
CONFIGURATION="${NOTCH_FINDER_BUILD_CONFIGURATION:-debug}"
SIGNING_IDENTITY="${NOTCH_FINDER_SIGNING_IDENTITY:-}"
APP_BUNDLE="$BUILD_DIR/dist/$APP_NAME.app"
APP_BINARY="$APP_BUNDLE/Contents/MacOS/$APP_NAME"

case "$MODE" in
  run|--build|--debug|--logs|--telemetry|--verify) ;;
  *)
    echo "usage: $0 [run|--build|--debug|--logs|--telemetry|--verify]" >&2
    exit 2
    ;;
esac

if [[ "$MODE" != "--build" ]]; then
  pkill -x "$APP_NAME" >/dev/null 2>&1 || true
fi

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
BUILD_BINARY="$("${SWIFT_BUILD[@]}" --show-bin-path)/$APP_NAME"

mkdir -p "$APP_BUNDLE/Contents/MacOS"
install -m 755 "$BUILD_BINARY" "$APP_BINARY"
/usr/bin/ditto "$PROJECT_DIR/Resources" "$APP_BUNDLE/Contents/Resources"

cat > "$APP_BUNDLE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>zh-Hant</string>
  <key>CFBundleDisplayName</key><string>Notch Finder</string>
  <key>CFBundleExecutable</key><string>$APP_NAME</string>
  <key>CFBundleIconFile</key><string>NotchFinder</string>
  <key>CFBundleIconName</key><string>NotchFinder</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleName</key><string>Notch Finder</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.66</string>
  <key>CFBundleVersion</key><string>66</string>
  <key>LSMinimumSystemVersion</key><string>$MACOS_MIN_VERSION</string>
  <key>LSUIElement</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
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
/usr/bin/codesign --force --sign "${SIGNING_IDENTITY:--}" --timestamp=none "$APP_BUNDLE"

open_app() {
  /usr/bin/open -n "$APP_BUNDLE"
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
  --verify)
    open_app
    sleep 1
    pgrep -x "$APP_NAME"
    ;;
esac
