#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="Pace"
PROCESS_NAME="Headroom"
BUNDLE_ID="com.amitpatnaik.pace"
MIN_SYSTEM_VERSION="13.0"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
LEGACY_APP_BUNDLE="$DIST_DIR/PaceDesk.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_RESOURCES="$APP_CONTENTS/Resources"
APP_BINARY="$APP_MACOS/$PROCESS_NAME"
INFO_PLIST="$APP_CONTENTS/Info.plist"
APP_ICON="$APP_RESOURCES/AppIcon.icns"
PRIVACY_MANIFEST="$ROOT_DIR/Resources/PrivacyInfo.xcprivacy"
SAMPLE_SNAPSHOT="$ROOT_DIR/Resources/PaceSnapshot.sample.json"

cd "$ROOT_DIR"

pkill -x "$PROCESS_NAME" >/dev/null 2>&1 || true

swift build
BUILD_BINARY="$(swift build --show-bin-path)/$PROCESS_NAME"

rm -rf "$APP_BUNDLE" "$LEGACY_APP_BUNDLE"
mkdir -p "$APP_MACOS" "$APP_RESOURCES"
"$ROOT_DIR/scripts/generate-app-icon.sh" >/dev/null
cp "$BUILD_BINARY" "$APP_BINARY"
cp "$ROOT_DIR/assets/AppIcon.icns" "$APP_ICON"
cp "$PRIVACY_MANIFEST" "$APP_RESOURCES/PrivacyInfo.xcprivacy"
cp "$SAMPLE_SNAPSHOT" "$APP_RESOURCES/PaceSnapshot.sample.json"
chmod +x "$APP_BINARY"

cat >"$INFO_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>$PROCESS_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleName</key>
  <string>$APP_NAME</string>
  <key>CFBundleDisplayName</key>
  <string>$APP_NAME</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>0.1.1</string>
  <key>CFBundleVersion</key>
  <string>0.1.1</string>
  <key>LSMinimumSystemVersion</key>
  <string>$MIN_SYSTEM_VERSION</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
</dict>
</plist>
PLIST

/usr/bin/codesign --force --deep --sign - "$APP_BUNDLE" >/dev/null

open_app() {
  /usr/bin/open -n "$APP_BUNDLE"
}

case "$MODE" in
  run)
    open_app
    ;;
  --debug|debug)
    lldb -- "$APP_BINARY"
    ;;
  --logs|logs)
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$PROCESS_NAME\""
    ;;
  --telemetry|telemetry)
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify|verify)
    open_app
    sleep 1
    pgrep -x "$PROCESS_NAME" >/dev/null
    "$APP_BINARY" --dump-summary >/tmp/pace-dump-summary.txt
    test -s /tmp/pace-dump-summary.txt
    "$APP_BINARY" --verify-popover-action >/tmp/pace-popover-action.txt
    grep -q 'verify_popover_action=pass' /tmp/pace-popover-action.txt
    ;;
  *)
    echo "usage: $0 [run|--debug|--logs|--telemetry|--verify]" >&2
    exit 2
    ;;
esac
