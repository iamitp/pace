#!/usr/bin/env bash
set -euo pipefail

APP_NAME="PaceDesk"
PROCESS_NAME="Headroom"
BUNDLE_ID="com.amitpatnaik.pace"
APP_IDENTITY="${PACE_APPSTORE_APP_IDENTITY:-3rd Party Mac Developer Application: Amit Patnaik (AVGA7YK5X2)}"
INSTALLER_IDENTITY="${PACE_APPSTORE_INSTALLER_IDENTITY:-3rd Party Mac Developer Installer: Amit Patnaik (AVGA7YK5X2)}"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RELEASE_DIR="$ROOT_DIR/release/app-store"
APP_BUNDLE="$RELEASE_DIR/$APP_NAME.app"
APP_BINARY="$APP_BUNDLE/Contents/MacOS/$PROCESS_NAME"
APP_ICON="$APP_BUNDLE/Contents/Resources/AppIcon.icns"
PRIVACY_MANIFEST="$APP_BUNDLE/Contents/Resources/PrivacyInfo.xcprivacy"
SAMPLE_SNAPSHOT="$APP_BUNDLE/Contents/Resources/PaceSnapshot.sample.json"
PKG="$RELEASE_DIR/${APP_NAME}-AppStore.pkg"
ENTITLEMENTS="$ROOT_DIR/entitlements/AppStore.entitlements"
ASSET_VERIFIER="$ROOT_DIR/scripts/verify-app-store-assets.sh"
PROFILE_DIRS=(
  "$HOME/Library/MobileDevice/Provisioning Profiles"
  "$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"
)

failures=()
warnings=()

find_transporter() {
  if [[ -n "${PACE_TRANSPORTER:-}" && -x "$PACE_TRANSPORTER" ]]; then
    echo "$PACE_TRANSPORTER"
    return 0
  fi

  local candidate
  for candidate in \
    "$ROOT_DIR/.local-tools/iTMSTransporter-root/bin/iTMSTransporter" \
    "/usr/local/itms/bin/iTMSTransporter" \
    "/Applications/Transporter.app/Contents/itms/bin/iTMSTransporter"
  do
    if [[ -x "$candidate" ]]; then
      echo "$candidate"
      return 0
    fi
  done

  /usr/bin/xcrun --find iTMSTransporter 2>/dev/null || true
}

has_upload_credentials() {
  if [[ -n "${PACE_TRANSPORTER_JWT:-}" ]]; then
    return 0
  fi
  if [[ -n "${PACE_ASC_API_KEY:-}" && -n "${PACE_ASC_API_ISSUER:-}" ]]; then
    return 0
  fi
  if [[ -n "${PACE_APPLE_ID:-}" && -n "${PACE_APP_SPECIFIC_PASSWORD:-}" ]]; then
    return 0
  fi
  return 1
}

selected_developer_dir="$(/usr/bin/xcode-select -p 2>/dev/null || true)"
echo "selected_developer_dir=${selected_developer_dir:-missing}"
full_xcode_selected=0
if [[ "$selected_developer_dir" != /Applications/Xcode*.app/Contents/Developer* ]]; then
  echo "full_xcode=not_selected"
else
  full_xcode_selected=1
  echo "full_xcode=selected"
fi

transporter_bin="$(find_transporter || true)"
if [[ -n "$transporter_bin" ]]; then
  transporter_version="$("$transporter_bin" -version 2>&1 | /usr/bin/awk '/iTMSTransporter, version/{print $NF; exit}' || true)"
  echo "upload_tool=$transporter_bin"
  echo "upload_tool_version=${transporter_version:-unknown}"
  if (( full_xcode_selected == 1 )); then
    echo "developer_tooling=full_xcode"
  else
    echo "developer_tooling=local_transporter"
  fi
else
  echo "upload_tool=missing"
  echo "developer_tooling=missing"
  failures+=("Transporter upload tooling is unavailable")
fi

if has_upload_credentials; then
  echo "upload_credentials=present"
else
  echo "upload_credentials=missing"
  failures+=("upload credentials are missing")
fi

if ! /usr/bin/security find-identity -v -p codesigning | /usr/bin/grep -F "$APP_IDENTITY" >/dev/null; then
  failures+=("missing app signing identity: $APP_IDENTITY")
else
  echo "app_signing_identity=present"
fi

if ! /usr/bin/security find-certificate -c "$INSTALLER_IDENTITY" >/dev/null 2>&1; then
  failures+=("missing installer certificate: $INSTALLER_IDENTITY")
else
  echo "installer_certificate=present"
fi

profile_dir_count=0
profile_count=0
matching_profile_count=0
for profiles_dir in "${PROFILE_DIRS[@]}"; do
  if [[ -d "$profiles_dir" ]]; then
    profile_dir_count=$((profile_dir_count + 1))
    while IFS= read -r profile; do
      profile_count=$((profile_count + 1))
      if /usr/bin/security cms -D -i "$profile" 2>/dev/null | /usr/bin/grep -F "$BUNDLE_ID" >/dev/null; then
        matching_profile_count=$((matching_profile_count + 1))
      fi
    done < <(find "$profiles_dir" -maxdepth 1 -type f)
  fi
done
echo "provisioning_profile_dirs=$profile_dir_count"
echo "provisioning_profiles=$profile_count"
echo "matching_provisioning_profiles=$matching_profile_count"
embedded_profile_matches=0

if [[ ! -f "$ENTITLEMENTS" ]]; then
  failures+=("missing App Store entitlements file")
else
  echo "entitlements_file=present"
fi

if [[ -x "$ASSET_VERIFIER" ]]; then
  if asset_output="$("$ASSET_VERIFIER" 2>&1)"; then
    printf '%s\n' "$asset_output"
  else
    asset_status=$?
    printf '%s\n' "$asset_output"
    echo "app_store_assets_exit_status=$asset_status"
    failures+=("App Store screenshot assets are missing or invalid")
  fi
else
  failures+=("missing App Store asset verifier")
fi

if [[ ! -d "$APP_BUNDLE" ]]; then
  failures+=("missing App Store app bundle; run scripts/package-app-store.sh")
else
  /usr/bin/codesign --verify --strict "$APP_BUNDLE" || failures+=("codesign verification failed for $APP_BUNDLE")
  bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP_BUNDLE/Contents/Info.plist" 2>/dev/null || true)"
  distribution="$("$ROOT_DIR/.build/release/$PROCESS_NAME" --dump-summary 2>/dev/null | /usr/bin/awk -F= '/^distribution=/{print $2}' || true)"
  entitlements_plist="$(/usr/bin/mktemp)"
  /usr/bin/codesign -d --entitlements :- "$APP_BUNDLE" >"$entitlements_plist" 2>/dev/null || true
  entitlements_text="$(/bin/cat "$entitlements_plist")"
  echo "bundle_id=${bundle_id:-missing}"
  echo "distribution=${distribution:-missing}"
  if [[ "$bundle_id" != "$BUNDLE_ID" ]]; then
    failures+=("bundle id mismatch: ${bundle_id:-missing}")
  fi
  icon_file="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' "$APP_BUNDLE/Contents/Info.plist" 2>/dev/null || true)"
  echo "bundle_icon=${icon_file:-missing}"
  if [[ "$icon_file" != "AppIcon" || ! -f "$APP_ICON" ]]; then
    failures+=("app bundle icon is missing")
  fi
	  if [[ -f "$PRIVACY_MANIFEST" ]]; then
    echo "privacy_manifest=present"
    /usr/bin/plutil -lint "$PRIVACY_MANIFEST" >/dev/null || failures+=("privacy manifest is invalid")
    privacy_tracking="$(/usr/libexec/PlistBuddy -c 'Print :NSPrivacyTracking' "$PRIVACY_MANIFEST" 2>/dev/null || true)"
    echo "privacy_tracking=${privacy_tracking:-missing}"
    if [[ "$privacy_tracking" != "false" ]]; then
      failures+=("privacy manifest tracking flag is not false")
    fi
	  else
	    echo "privacy_manifest=missing"
	    failures+=("privacy manifest is missing")
	  fi
	  if [[ -f "$SAMPLE_SNAPSHOT" ]]; then
	    echo "sample_snapshot=present"
	    /usr/bin/python3 -m json.tool "$SAMPLE_SNAPSHOT" >/dev/null || failures+=("sample snapshot JSON is invalid")
	  else
	    echo "sample_snapshot=missing"
	    failures+=("sample snapshot is missing")
	  fi
	  if [[ "$distribution" != "app-store" ]]; then
	    failures+=("binary was not compiled with APPSTORE mode")
	  fi
  if ! /usr/bin/grep -q "com.apple.security.app-sandbox" <<<"$entitlements_text"; then
    failures+=("signed app does not include sandbox entitlement")
	  else
	    echo "sandbox_entitlement=present"
	  fi
	  if ! /usr/bin/grep -q "com.apple.security.files.user-selected.read-only" <<<"$entitlements_text"; then
	    failures+=("signed app does not include read-only user-selected file entitlement")
	  else
	    echo "user_selected_read_only_entitlement=present"
	  fi
  app_identifier="$(/usr/libexec/PlistBuddy -c 'Print :com.apple.application-identifier' "$entitlements_plist" 2>/dev/null || true)"
  team_identifier="$(/usr/libexec/PlistBuddy -c 'Print :com.apple.developer.team-identifier' "$entitlements_plist" 2>/dev/null || true)"
  /bin/rm -f "$entitlements_plist"
  echo "application_identifier_entitlement=${app_identifier:-missing}"
  echo "team_identifier_entitlement=${team_identifier:-missing}"
  if [[ "$app_identifier" != "AVGA7YK5X2.$BUNDLE_ID" ]]; then
    failures+=("signed app does not include matching application identifier entitlement")
  fi
  if [[ "$team_identifier" != "AVGA7YK5X2" ]]; then
    failures+=("signed app does not include matching team identifier entitlement")
  fi
  if /usr/bin/xattr -rl "$APP_BUNDLE" 2>/dev/null | /usr/bin/grep -q "com.apple.quarantine"; then
    echo "quarantine_xattrs=present"
    failures+=("app bundle contains com.apple.quarantine extended attributes")
  else
    echo "quarantine_xattrs=absent"
  fi
  embedded_profile="$APP_BUNDLE/Contents/embedded.provisionprofile"
  if [[ -f "$embedded_profile" ]]; then
    echo "embedded_provisioning_profile=present"
    if /usr/bin/security cms -D -i "$embedded_profile" 2>/dev/null | /usr/bin/grep -F "$BUNDLE_ID" >/dev/null; then
      embedded_profile_matches=1
      echo "embedded_provisioning_profile_matches_bundle=true"
    else
      echo "embedded_provisioning_profile_matches_bundle=false"
      failures+=("embedded provisioning profile does not match $BUNDLE_ID")
    fi
  else
    echo "embedded_provisioning_profile=missing"
  fi
fi

if [[ "$matching_profile_count" == "0" && "$embedded_profile_matches" == "0" ]]; then
  failures+=("no installed or embedded provisioning profile for $BUNDLE_ID")
fi

if [[ ! -f "$PKG" ]]; then
  failures+=("missing signed product package; run scripts/package-app-store.sh")
else
  /usr/sbin/pkgutil --check-signature "$PKG" >/dev/null || failures+=("pkg signature check failed")
  echo "product_package=present"
fi

if (( ${#warnings[@]} > 0 )); then
  for warning in "${warnings[@]}"; do
    echo "warning=$warning"
  done
fi

if (( ${#failures[@]} > 0 )); then
  echo "app_store_readiness=blocked"
  for failure in "${failures[@]}"; do
    echo "blocker=$failure"
  done
  exit 1
fi

echo "app_store_readiness=pass"
