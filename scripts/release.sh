#!/usr/bin/env bash
set -euo pipefail

# Release pipeline for Pace app
# Usage: ./scripts/release.sh VERSION [--skip-notarize]
# Example: ./scripts/release.sh 1.0.0
#          ./scripts/release.sh 1.0.0 --skip-notarize

VERSION="${1:?Version argument required (e.g. 1.0.0)}"
SKIP_NOTARIZE=false

if [[ "${2:-}" == "--skip-notarize" ]]; then
  SKIP_NOTARIZE=true
fi

# Configuration
APP_NAME="Pace"
PROCESS_NAME="Headroom"
BUNDLE_ID="com.amitpatnaik.pace"
MIN_SYSTEM_VERSION="13.0"
SIGNING_IDENTITY="Developer ID Application: Amit Patnaik (AVGA7YK5X2)"
TEAM_ID="AVGA7YK5X2"

# Paths
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
RELEASE_DIR="$ROOT_DIR/release/artifacts"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_RESOURCES="$APP_CONTENTS/Resources"
APP_BINARY="$APP_MACOS/$PROCESS_NAME"
INFO_PLIST="$APP_CONTENTS/Info.plist"
APP_ICON="$APP_RESOURCES/AppIcon.icns"
PRIVACY_MANIFEST="$ROOT_DIR/Resources/PrivacyInfo.xcprivacy"
SAMPLE_SNAPSHOT="$ROOT_DIR/Resources/PaceSnapshot.sample.json"
ENTITLEMENTS_FILE="$ROOT_DIR/entitlements/AppStore.entitlements"

# Create artifacts directory
mkdir -p "$RELEASE_DIR"

echo "========================================="
echo "Pace Release Pipeline v$VERSION"
echo "========================================="

# Stage 1: Build (RELEASE configuration)
echo ""
echo "Stage 1: Building RELEASE configuration binary..."
cd "$ROOT_DIR"
swift build -c release
BUILD_BINARY="$(swift build -c release --show-bin-path)/$PROCESS_NAME"
echo "✓ Built: $BUILD_BINARY"

# Stage 2: Assemble bundle
echo ""
echo "Stage 2: Assembling app bundle..."
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_MACOS" "$APP_RESOURCES"
echo "  Copying binary..."
cp "$BUILD_BINARY" "$APP_BINARY"
echo "  Copying icon..."
cp "$ROOT_DIR/assets/AppIcon.icns" "$APP_ICON"
echo "  Copying privacy manifest..."
cp "$PRIVACY_MANIFEST" "$APP_RESOURCES/PrivacyInfo.xcprivacy"
echo "  Copying sample snapshot..."
cp "$SAMPLE_SNAPSHOT" "$APP_RESOURCES/PaceSnapshot.sample.json"
chmod +x "$APP_BINARY"
echo "✓ Bundle assembled: $APP_BUNDLE"

# Stage 3: Update Info.plist with version
echo ""
echo "Stage 3: Updating Info.plist with version $VERSION..."
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
  <string>$VERSION</string>
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
echo "✓ Info.plist updated with CFBundleShortVersionString=$VERSION"

# Stage 4: Code sign with Developer ID + hardened runtime
echo ""
echo "Stage 4: Code signing with Developer ID and hardened runtime..."
echo "  Identity: $SIGNING_IDENTITY"
echo "  Entitlements: $ENTITLEMENTS_FILE"

# Note: AppStore.entitlements has sandbox enabled, which is not suitable for Developer ID.
# Create a Developer ID entitlements file without sandbox.
DEVID_ENTITLEMENTS="$ROOT_DIR/entitlements/DeveloperID.entitlements"
cat >"$DEVID_ENTITLEMENTS" <<ENT
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>com.apple.security.cs.allow-jit</key>
  <true/>
  <key>com.apple.security.cs.allow-unsigned-executable-memory</key>
  <true/>
  <key>com.apple.security.cs.disable-executable-page-protection</key>
  <true/>
</dict>
</plist>
ENT

/usr/bin/codesign \
  --force \
  --deep \
  --options runtime \
  --timestamp \
  --entitlements "$DEVID_ENTITLEMENTS" \
  --sign "$SIGNING_IDENTITY" \
  "$APP_BUNDLE"
echo "✓ Code signed successfully"

# Stage 5: Verify signature
echo ""
echo "Stage 5: Verifying signature..."
/usr/bin/codesign --verify --deep --strict "$APP_BUNDLE" 2>&1 | sed 's/^/  /'
echo "✓ Signature verified (--deep --strict)"

# Check with spctl (will fail before notarisation, but we report anyway)
echo "  Checking with spctl (will fail before notarisation)..."
if spctl -a -t exec -vvv "$APP_BUNDLE" 2>&1 | sed 's/^/  /'; then
  echo "  Note: spctl passed (app is notarised or system trusts ad-hoc)"
else
  echo "  Note: spctl failed (expected pre-notarisation)"
fi

# Stage 6: Notarisation (if not skipped)
if [[ "$SKIP_NOTARIZE" == "true" ]]; then
  echo ""
  echo "Stage 6: SKIPPED (--skip-notarize flag set)"
  echo "  Notarisation and stapling skipped."
  FINAL_ARTIFACT="$DIST_DIR/$APP_NAME.app"
  echo "✓ Build complete (unsigned for distribution): $FINAL_ARTIFACT"
else
  echo ""
  echo "Stage 6: Preparing for notarisation..."

  # Create temp zip for notarisation
  NOTARY_ZIP="/tmp/pace-notary-$VERSION.zip"
  echo "  Creating notarisation zip: $NOTARY_ZIP"
  ditto -c -k "$APP_BUNDLE" "$NOTARY_ZIP"
  echo "✓ Zip created"

  # Detect notarisation credentials
  echo ""
  echo "Stage 7: Detecting notarisation credentials..."

  NOTARY_CREDENTIALS_FOUND=false
  NOTARY_KEY_ID=""
  NOTARY_ISSUER=""

  # Check for keychain profile
  if xcrun notarytool history --keychain-profile pace-notary >/dev/null 2>&1; then
    echo "✓ Found keychain profile: pace-notary"
    NOTARY_CREDENTIALS_FOUND=true
  else
    echo "  No keychain profile 'pace-notary' found"

    # Check for App Store Connect API keys
    if [[ -f "$HOME/.appstoreconnect/private_keys/AuthKey_7379D3J5AG.p8" ]]; then
      NOTARY_KEY_ID="7379D3J5AG"
      NOTARY_CREDENTIALS_FOUND=true
      echo "✓ Found App Store Connect API key: AuthKey_$NOTARY_KEY_ID.p8"

      # Attempt to detect issuer from App Store Connect API response (requires existing config)
      # For now, we'll instruct the user if no stored issuer is available
      if [[ ! -f "$HOME/.appstoreconnect/issuer.txt" ]]; then
        echo "  WARNING: Issuer ID not stored. Will attempt submission and report issuer requirement."
      else
        NOTARY_ISSUER=$(cat "$HOME/.appstoreconnect/issuer.txt")
        echo "  Using stored issuer: $NOTARY_ISSUER"
      fi
    elif [[ -f "$HOME/.appstoreconnect/private_keys/AuthKey_JZFM6G38XP.p8" ]]; then
      NOTARY_KEY_ID="JZFM6G38XP"
      NOTARY_CREDENTIALS_FOUND=true
      echo "✓ Found App Store Connect API key: AuthKey_$NOTARY_KEY_ID.p8"

      if [[ ! -f "$HOME/.appstoreconnect/issuer.txt" ]]; then
        echo "  WARNING: Issuer ID not stored. Will attempt submission and report issuer requirement."
      else
        NOTARY_ISSUER=$(cat "$HOME/.appstoreconnect/issuer.txt")
        echo "  Using stored issuer: $NOTARY_ISSUER"
      fi
    fi
  fi

  if [[ "$NOTARY_CREDENTIALS_FOUND" == "false" ]]; then
    echo ""
    echo "ERROR: No notarisation credentials found."
    echo ""
    echo "To set up notarisation credentials, run:"
    echo "  xcrun notarytool store-credentials pace-notary \\"
    echo "    --apple-id <your-apple-id> \\"
    echo "    --team-id $TEAM_ID \\"
    echo "    --password <app-specific-password>"
    echo ""
    echo "Or place App Store Connect API key at:"
    echo "  ~/.appstoreconnect/private_keys/AuthKey_<KEY_ID>.p8"
    echo ""
    rm -f "$NOTARY_ZIP"
    exit 2
  fi

  # Submit for notarisation
  echo ""
  echo "Stage 8: Submitting to Apple Notary Service..."
  echo "  ZIP: $NOTARY_ZIP"

  NOTARY_ARGS=("submit" "--wait" "$NOTARY_ZIP")

  if [[ "$NOTARY_CREDENTIALS_FOUND" == "true" && "$NOTARY_KEY_ID" != "" ]]; then
    if [[ "$NOTARY_ISSUER" == "" ]]; then
      echo "  ERROR: Issuer ID required for API key authentication but not found."
      echo "  Please store issuer ID at: ~/.appstoreconnect/issuer.txt"
      rm -f "$NOTARY_ZIP"
      exit 2
    fi
    NOTARY_ARGS+=(
      "--key" "$HOME/.appstoreconnect/private_keys/AuthKey_$NOTARY_KEY_ID.p8"
      "--key-id" "$NOTARY_KEY_ID"
      "--issuer" "$NOTARY_ISSUER"
    )
    echo "  Using API key credentials (key: $NOTARY_KEY_ID, issuer: $NOTARY_ISSUER)"
  else
    NOTARY_ARGS+=(
      "--keychain-profile" "pace-notary"
    )
    echo "  Using keychain profile: pace-notary"
  fi

  # Submit
  if xcrun notarytool "${NOTARY_ARGS[@]}"; then
    echo "✓ Notarisation successful"
  else
    echo "ERROR: Notarisation failed"
    rm -f "$NOTARY_ZIP"
    exit 1
  fi

  # Stage 9: Staple ticket
  echo ""
  echo "Stage 9: Stapling notarisation ticket..."
  xcrun stapler staple "$APP_BUNDLE"
  echo "✓ Stapled successfully"

  # Clean up temp zip
  rm -f "$NOTARY_ZIP"
fi

# Stage 10: Create final release artifact
echo ""
echo "Stage 10: Creating release artifact..."
FINAL_ARTIFACT="$RELEASE_DIR/Pace-v${VERSION}.zip"
echo "  Creating: $FINAL_ARTIFACT"
ditto -c -k --keepParent "$APP_BUNDLE" "$FINAL_ARTIFACT"
echo "✓ Release artifact: $FINAL_ARTIFACT"

echo ""
echo "========================================="
echo "Release Complete!"
echo "========================================="
echo "Version: $VERSION"
echo "Artifact: $FINAL_ARTIFACT"
if [[ "$SKIP_NOTARIZE" == "true" ]]; then
  echo "Status: NOT NOTARISED (--skip-notarize was set)"
else
  echo "Status: Notarised and stapled"
fi
echo "========================================="
