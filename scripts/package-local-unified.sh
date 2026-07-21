#!/usr/bin/env bash

set -euo pipefail
IFS=$'\n\t'
umask 022

fail() {
  printf 'Pace local package: %s\n' "$1" >&2
  exit 1
}

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
APP_NAME="Pace"
PROCESS_NAME="Headroom"
BUNDLE_ID="com.amitpatnaik.pace"
VERSION="1.4.3"
BUILD_NUMBER="143"
MIN_SYSTEM_VERSION="13.0"

DEFAULT_APP_BUNDLE="$ROOT_DIR/dist/Pace-$VERSION.app"
APP_BUNDLE="${PACE_STAGE_APP:-$DEFAULT_APP_BUNDLE}"

[[ "$APP_BUNDLE" == /* ]] || fail "PACE_STAGE_APP must be an absolute path."
[[ "$APP_BUNDLE" == *.app ]] || fail "PACE_STAGE_APP must end in .app."
[[ "$APP_BUNDLE" != "/" && "$APP_BUNDLE" != "$HOME" ]] || fail "refusing an unsafe staging path."
case "$APP_BUNDLE" in
  /Applications/*|/System/Applications/*|/Network/Applications/*|"$HOME"/Applications/*)
    fail "PACE_STAGE_APP must be a staging location, not an Applications directory."
    ;;
esac
[[ ! -e "$APP_BUNDLE" && ! -L "$APP_BUNDLE" ]] || fail "the staging path already exists: $APP_BUNDLE"

OUTPUT_PARENT="$(dirname "$APP_BUNDLE")"
APP_BASENAME="$(basename "$APP_BUNDLE")"
mkdir -p "$OUTPUT_PARENT"
OUTPUT_PARENT="$(cd "$OUTPUT_PARENT" && pwd -P)"
APP_BUNDLE="$OUTPUT_PARENT/$APP_BASENAME"
[[ ! -e "$APP_BUNDLE" && ! -L "$APP_BUNDLE" ]] || fail "the resolved staging path already exists: $APP_BUNDLE"

SOURCE_ICON="$ROOT_DIR/assets/AppIcon.icns"
SOURCE_PRIVACY="$ROOT_DIR/Resources/PrivacyInfo.xcprivacy"
SOURCE_SAMPLE="$ROOT_DIR/Resources/PaceSnapshot.sample.json"
SOURCE_LAUNCHER="$ROOT_DIR/scripts/pace-managed-codex.command"
SOURCE_SESH_LAUNCHER="$ROOT_DIR/scripts/pace-sesh"
SOURCE_SESH_INTEGRATION_INSTALLER="$ROOT_DIR/scripts/install-sesh-native-integration.sh"
SESH_SOURCE_ROOT="${SESH_SOURCE_ROOT:-$ROOT_DIR/../sesh}"
SESH_SOURCE_ROOT="$(cd "$SESH_SOURCE_ROOT" && pwd -P)"
SESH_MODULES=(sesh.py auto.py managed.py policy_v2.py conductor.py claude_managed.py gears.py speed.py cadence.py antilug.py fuel.py toggle.py)
SESH_AGENT_PROFILES=(sesh-mechanical.toml sesh-scout.toml sesh-worker.toml sesh-reviewer.toml)

for source_file in "$SOURCE_ICON" "$SOURCE_PRIVACY" "$SOURCE_SAMPLE" "$SOURCE_LAUNCHER" "$SOURCE_SESH_LAUNCHER" "$SOURCE_SESH_INTEGRATION_INSTALLER"; do
  [[ -f "$source_file" && -r "$source_file" ]] || fail "required source file is unavailable: $source_file"
done
for module in "${SESH_MODULES[@]}"; do
  [[ -f "$SESH_SOURCE_ROOT/$module" && -r "$SESH_SOURCE_ROOT/$module" && ! -L "$SESH_SOURCE_ROOT/$module" ]] || fail "required Sesh module is unavailable: $SESH_SOURCE_ROOT/$module"
done
[[ -f "$SESH_SOURCE_ROOT/integration/AGENTS.sesh.md" ]] || fail "the native Sesh instruction fragment is unavailable."
[[ -f "$SESH_SOURCE_ROOT/integration/config.sesh.toml" && ! -L "$SESH_SOURCE_ROOT/integration/config.sesh.toml" ]] || fail "the native Sesh config fragment is unavailable."
for profile in "${SESH_AGENT_PROFILES[@]}"; do
  [[ -f "$SESH_SOURCE_ROOT/integration/agents/$profile" && ! -L "$SESH_SOURCE_ROOT/integration/agents/$profile" ]] || fail "a native Sesh worker profile is unavailable: $profile"
done

cd "$ROOT_DIR"
swift build -c release
BUILD_DIRECTORY="$(swift build -c release --show-bin-path)"
BUILD_BINARY="$BUILD_DIRECTORY/$PROCESS_NAME"
[[ -f "$BUILD_BINARY" && -x "$BUILD_BINARY" ]] || fail "release binary is unavailable: $BUILD_BINARY"

STAGE_ROOT="$(mktemp -d "$OUTPUT_PARENT/.${APP_BASENAME}.stage.XXXXXX")"
STAGE_APP="$STAGE_ROOT/$APP_BASENAME"
STAGE_CONTENTS="$STAGE_APP/Contents"
STAGE_MACOS="$STAGE_CONTENTS/MacOS"
STAGE_RESOURCES="$STAGE_CONTENTS/Resources"
STAGE_BINARY="$STAGE_MACOS/$PROCESS_NAME"
STAGE_INFO_PLIST="$STAGE_CONTENTS/Info.plist"
STAGE_ICON="$STAGE_RESOURCES/AppIcon.icns"
STAGE_PRIVACY="$STAGE_RESOURCES/PrivacyInfo.xcprivacy"
STAGE_SAMPLE="$STAGE_RESOURCES/PaceSnapshot.sample.json"
STAGE_LAUNCHER="$STAGE_RESOURCES/Pace Managed Codex.command"
STAGE_SESH="$STAGE_RESOURCES/Sesh"
STAGE_SESH_LAUNCHER="$STAGE_SESH/sesh"
STAGE_SESH_INTEGRATION_INSTALLER="$STAGE_SESH/install-native-integration"
STAGE_SESH_INTEGRATION="$STAGE_SESH/integration"
STAGE_SESH_AGENTS="$STAGE_SESH_INTEGRATION/agents"

cleanup() {
  if [[ -n "${STAGE_ROOT:-}" && -d "$STAGE_ROOT" ]]; then
    case "$STAGE_ROOT" in
      "$OUTPUT_PARENT"/."$APP_BASENAME".stage.*)
        rm -rf "$STAGE_ROOT"
        ;;
      *)
        printf 'Pace local package: refusing to clean an unexpected staging path: %s\n' "$STAGE_ROOT" >&2
        ;;
    esac
  fi
}
trap cleanup EXIT

mkdir -p "$STAGE_MACOS" "$STAGE_RESOURCES" "$STAGE_SESH" "$STAGE_SESH_AGENTS"
install -m 0755 "$BUILD_BINARY" "$STAGE_BINARY"
install -m 0644 "$SOURCE_ICON" "$STAGE_ICON"
install -m 0644 "$SOURCE_PRIVACY" "$STAGE_PRIVACY"
install -m 0644 "$SOURCE_SAMPLE" "$STAGE_SAMPLE"
install -m 0755 "$SOURCE_LAUNCHER" "$STAGE_LAUNCHER"
install -m 0755 "$SOURCE_SESH_LAUNCHER" "$STAGE_SESH_LAUNCHER"
install -m 0755 "$SOURCE_SESH_INTEGRATION_INSTALLER" "$STAGE_SESH_INTEGRATION_INSTALLER"
for module in "${SESH_MODULES[@]}"; do
  install -m 0644 "$SESH_SOURCE_ROOT/$module" "$STAGE_SESH/$module"
done
install -m 0644 "$SESH_SOURCE_ROOT/integration/AGENTS.sesh.md" "$STAGE_SESH_INTEGRATION/AGENTS.sesh.md"
install -m 0644 "$SESH_SOURCE_ROOT/integration/config.sesh.toml" "$STAGE_SESH_INTEGRATION/config.sesh.toml"
for profile in "${SESH_AGENT_PROFILES[@]}"; do
  install -m 0644 "$SESH_SOURCE_ROOT/integration/agents/$profile" "$STAGE_SESH_AGENTS/$profile"
done

cat >"$STAGE_INFO_PLIST" <<PLIST
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
  <string>$BUILD_NUMBER</string>
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

/usr/bin/plutil -lint "$STAGE_INFO_PLIST" >/dev/null
[[ "$(/usr/bin/plutil -extract CFBundleShortVersionString raw -o - "$STAGE_INFO_PLIST")" == "$VERSION" ]] || fail "version verification failed."
[[ "$(/usr/bin/plutil -extract CFBundleVersion raw -o - "$STAGE_INFO_PLIST")" == "$BUILD_NUMBER" ]] || fail "build number verification failed."
[[ "$(/usr/bin/plutil -extract LSMinimumSystemVersion raw -o - "$STAGE_INFO_PLIST")" == "$MIN_SYSTEM_VERSION" ]] || fail "minimum system version verification failed."

cmp -s "$BUILD_BINARY" "$STAGE_BINARY" || fail "release binary copy verification failed."
cmp -s "$SOURCE_ICON" "$STAGE_ICON" || fail "icon copy verification failed."
cmp -s "$SOURCE_PRIVACY" "$STAGE_PRIVACY" || fail "privacy manifest copy verification failed."
cmp -s "$SOURCE_SAMPLE" "$STAGE_SAMPLE" || fail "sample snapshot copy verification failed."
cmp -s "$SOURCE_LAUNCHER" "$STAGE_LAUNCHER" || fail "managed launcher copy verification failed."
cmp -s "$SOURCE_SESH_LAUNCHER" "$STAGE_SESH_LAUNCHER" || fail "Sesh launcher copy verification failed."
cmp -s "$SOURCE_SESH_INTEGRATION_INSTALLER" "$STAGE_SESH_INTEGRATION_INSTALLER" || fail "Sesh integration installer copy verification failed."
for module in "${SESH_MODULES[@]}"; do
  cmp -s "$SESH_SOURCE_ROOT/$module" "$STAGE_SESH/$module" || fail "Sesh module copy verification failed: $module"
done
cmp -s "$SESH_SOURCE_ROOT/integration/AGENTS.sesh.md" "$STAGE_SESH_INTEGRATION/AGENTS.sesh.md" || fail "native Sesh instruction copy verification failed."
cmp -s "$SESH_SOURCE_ROOT/integration/config.sesh.toml" "$STAGE_SESH_INTEGRATION/config.sesh.toml" || fail "native Sesh config copy verification failed."
for profile in "${SESH_AGENT_PROFILES[@]}"; do
  cmp -s "$SESH_SOURCE_ROOT/integration/agents/$profile" "$STAGE_SESH_AGENTS/$profile" || fail "native Sesh worker profile copy verification failed: $profile"
done

[[ "$(stat -f '%Lp' "$STAGE_BINARY")" == "755" ]] || fail "release binary mode verification failed."
[[ "$(stat -f '%Lp' "$STAGE_LAUNCHER")" == "755" ]] || fail "managed launcher mode verification failed."
[[ "$(stat -f '%Lp' "$STAGE_SESH_LAUNCHER")" == "755" ]] || fail "Sesh launcher mode verification failed."
[[ "$(stat -f '%Lp' "$STAGE_SESH_INTEGRATION_INSTALLER")" == "755" ]] || fail "Sesh integration installer mode verification failed."
for module in "${SESH_MODULES[@]}"; do
  [[ "$(stat -f '%Lp' "$STAGE_SESH/$module")" == "644" ]] || fail "Sesh module mode verification failed: $module"
done
[[ "$(stat -f '%Lp' "$STAGE_SESH_INTEGRATION/AGENTS.sesh.md")" == "644" ]] || fail "native Sesh instruction mode verification failed."
[[ "$(stat -f '%Lp' "$STAGE_SESH_INTEGRATION/config.sesh.toml")" == "644" ]] || fail "native Sesh config mode verification failed."
for profile in "${SESH_AGENT_PROFILES[@]}"; do
  [[ "$(stat -f '%Lp' "$STAGE_SESH_AGENTS/$profile")" == "644" ]] || fail "native Sesh worker profile mode verification failed: $profile"
done
[[ "$(stat -f '%Lp' "$STAGE_INFO_PLIST")" == "644" ]] || fail "information property list mode verification failed."
[[ "$(stat -f '%Lp' "$STAGE_ICON")" == "644" ]] || fail "icon mode verification failed."
[[ "$(stat -f '%Lp' "$STAGE_PRIVACY")" == "644" ]] || fail "privacy manifest mode verification failed."
[[ "$(stat -f '%Lp' "$STAGE_SAMPLE")" == "644" ]] || fail "sample snapshot mode verification failed."

/usr/bin/codesign --force --deep --sign - "$STAGE_APP"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$STAGE_APP"
HOME="$(mktemp -d "$STAGE_ROOT/.sesh-home.XXXXXX")" "$STAGE_SESH_LAUNCHER" --version | /usr/bin/grep -Fxq 'Sesh 5.0.0' || fail "bundled Sesh version verification failed."

mv "$STAGE_APP" "$APP_BUNDLE"

HASH_MANIFEST="${APP_BUNDLE%.app}.bundle-sha256.txt"
[[ ! -e "$HASH_MANIFEST" && ! -L "$HASH_MANIFEST" ]] || fail "the bundle manifest path already exists: $HASH_MANIFEST"
HASH_MANIFEST_TEMP="$STAGE_ROOT/bundle-hashes.txt"
while IFS= read -r -d '' packaged_file; do
  relative_path="${packaged_file#"$APP_BUNDLE"/}"
  file_sha256="$(/usr/bin/shasum -a 256 "$packaged_file" | /usr/bin/awk '{print $1}')"
  printf '%s  %s\n' "$file_sha256" "$relative_path"
done < <(/usr/bin/find "$APP_BUNDLE" -type f -print0) | LC_ALL=C /usr/bin/sort >"$HASH_MANIFEST_TEMP"
install -m 0644 "$HASH_MANIFEST_TEMP" "$HASH_MANIFEST"
BUNDLE_MANIFEST_SHA256="$(/usr/bin/shasum -a 256 "$HASH_MANIFEST" | /usr/bin/awk '{print $1}')"

printf 'app_path=%s\n' "$APP_BUNDLE"
printf 'manifest_path=%s\n' "$HASH_MANIFEST"
printf 'bundle_manifest_sha256=%s\n' "$BUNDLE_MANIFEST_SHA256"
