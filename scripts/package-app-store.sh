#!/usr/bin/env bash
set -euo pipefail

APP_NAME="PaceDesk"
PROCESS_NAME="Headroom"
BUNDLE_ID="com.amitpatnaik.pace"
VERSION="${PACE_VERSION:-0.1.1}"
BUILD_VERSION="${PACE_BUILD_VERSION:-$VERSION}"
MIN_SYSTEM_VERSION="13.0"
APP_CATEGORY="public.app-category.developer-tools"
APP_IDENTITY="${PACE_APPSTORE_APP_IDENTITY:-3rd Party Mac Developer Application: Amit Patnaik (AVGA7YK5X2)}"
INSTALLER_IDENTITY="${PACE_APPSTORE_INSTALLER_IDENTITY:-3rd Party Mac Developer Installer: Amit Patnaik (AVGA7YK5X2)}"
TEAM_ID="AVGA7YK5X2"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RELEASE_DIR="$ROOT_DIR/release/app-store"
APP_BUNDLE="$RELEASE_DIR/$APP_NAME.app"
LEGACY_APP_BUNDLE="$RELEASE_DIR/Pace.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_RESOURCES="$APP_CONTENTS/Resources"
APP_BINARY="$APP_MACOS/$PROCESS_NAME"
INFO_PLIST="$APP_CONTENTS/Info.plist"
APP_ICON="$APP_RESOURCES/AppIcon.icns"
PRIVACY_MANIFEST="$ROOT_DIR/Resources/PrivacyInfo.xcprivacy"
SAMPLE_SNAPSHOT="$ROOT_DIR/Resources/PaceSnapshot.sample.json"
ENTITLEMENTS="$ROOT_DIR/entitlements/AppStore.entitlements"
PKG="$RELEASE_DIR/${APP_NAME}-AppStore.pkg"
LEGACY_PKG="$RELEASE_DIR/Pace-AppStore.pkg"
MANIFEST="$RELEASE_DIR/manifest.json"
DEFAULT_PROFILE="$RELEASE_DIR/Pace-AppStore.provisionprofile"

cd "$ROOT_DIR"

if ! /usr/bin/security find-identity -v -p codesigning | /usr/bin/grep -F "$APP_IDENTITY" >/dev/null; then
  echo "app_store_package=blocked reason=missing_app_signing_identity identity=\"$APP_IDENTITY\"" >&2
  exit 20
fi

if ! /usr/bin/security find-certificate -c "$INSTALLER_IDENTITY" >/dev/null 2>&1; then
  echo "app_store_package=blocked reason=missing_installer_certificate identity=\"$INSTALLER_IDENTITY\"" >&2
  exit 21
fi

if [[ ! -f "$ENTITLEMENTS" ]]; then
  echo "app_store_package=blocked reason=missing_entitlements path=\"$ENTITLEMENTS\"" >&2
  exit 22
fi

/usr/bin/swift build -c release -Xswiftc -DAPPSTORE
BUILD_BINARY="$(/usr/bin/swift build -c release --show-bin-path)/$PROCESS_NAME"

rm -rf "$APP_BUNDLE" "$PKG" "$LEGACY_APP_BUNDLE" "$LEGACY_PKG"
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
  <string>$VERSION</string>
  <key>CFBundleVersion</key>
  <string>$BUILD_VERSION</string>
  <key>LSApplicationCategoryType</key>
  <string>$APP_CATEGORY</string>
  <key>LSMinimumSystemVersion</key>
  <string>$MIN_SYSTEM_VERSION</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
  <key>ITSAppUsesNonExemptEncryption</key>
  <false/>
</dict>
</plist>
PLIST

PROFILE_TO_EMBED="${PACE_PROVISIONING_PROFILE:-}"
if [[ -z "$PROFILE_TO_EMBED" && -f "$DEFAULT_PROFILE" ]]; then
  PROFILE_TO_EMBED="$DEFAULT_PROFILE"
fi

if [[ -n "$PROFILE_TO_EMBED" ]]; then
  if [[ ! -f "$PROFILE_TO_EMBED" ]]; then
    echo "app_store_package=blocked reason=missing_provisioning_profile path=\"$PROFILE_TO_EMBED\"" >&2
    exit 23
  fi
  if ! /usr/bin/security cms -D -i "$PROFILE_TO_EMBED" 2>/dev/null | /usr/bin/grep -F "$BUNDLE_ID" >/dev/null; then
    echo "app_store_package=blocked reason=provisioning_profile_bundle_mismatch bundle_id=\"$BUNDLE_ID\" path=\"$PROFILE_TO_EMBED\"" >&2
    exit 24
  fi
  cp "$PROFILE_TO_EMBED" "$APP_CONTENTS/embedded.provisionprofile"
  /usr/bin/xattr -c "$APP_CONTENTS/embedded.provisionprofile" 2>/dev/null || true
  echo "app_store_package=profile_embedded path=\"$PROFILE_TO_EMBED\""
else
  echo "app_store_package=warning reason=no_embedded_provisioning_profile"
fi

/usr/bin/xattr -cr "$APP_BUNDLE" 2>/dev/null || true
/usr/bin/codesign --force --timestamp=none --options runtime --entitlements "$ENTITLEMENTS" --sign "$APP_IDENTITY" "$APP_BINARY"
/usr/bin/codesign --force --timestamp=none --options runtime --entitlements "$ENTITLEMENTS" --sign "$APP_IDENTITY" "$APP_BUNDLE"
/usr/bin/xattr -cr "$APP_BUNDLE" 2>/dev/null || true
/usr/bin/codesign --verify --strict "$APP_BUNDLE"
/usr/bin/codesign -dvvv --entitlements :- "$APP_BUNDLE" >"$RELEASE_DIR/codesign-details.txt" 2>&1 || true

/usr/bin/productbuild --component "$APP_BUNDLE" /Applications --sign "$INSTALLER_IDENTITY" "$PKG"
/usr/sbin/pkgutil --check-signature "$PKG" >"$RELEASE_DIR/pkg-signature.txt"

cat >"$MANIFEST" <<JSON
{
  "app": "$APP_BUNDLE",
  "pkg": "$PKG",
  "bundle_id": "$BUNDLE_ID",
  "version": "$VERSION",
  "build_version": "$BUILD_VERSION",
  "app_identity": "$APP_IDENTITY",
  "installer_identity": "$INSTALLER_IDENTITY",
  "distribution": "app-store",
  "provisioning_profile_embedded": $(if [[ -n "$PROFILE_TO_EMBED" ]]; then echo "true"; else echo "false"; fi)
}
JSON

echo "app_store_package=pass app=\"$APP_BUNDLE\" pkg=\"$PKG\""
