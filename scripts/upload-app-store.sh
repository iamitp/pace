#!/usr/bin/env bash
set -euo pipefail

APP_NAME="PaceDesk"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PKG="${PACE_APPSTORE_PKG:-$ROOT_DIR/release/app-store/${APP_NAME}-AppStore.pkg}"
APP_BUNDLE="$ROOT_DIR/release/app-store/${APP_NAME}.app"
MANIFEST="$ROOT_DIR/release/app-store/manifest.json"

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

if [[ ! -f "$PKG" ]]; then
  echo "app_store_upload=blocked reason=missing_pkg path=\"$PKG\"" >&2
  exit 30
fi

if ! /usr/sbin/pkgutil --check-signature "$PKG" >/dev/null; then
  echo "app_store_upload=blocked reason=invalid_pkg_signature path=\"$PKG\"" >&2
  exit 33
fi

if [[ -d "$APP_BUNDLE" && ! -f "$APP_BUNDLE/Contents/embedded.provisionprofile" ]]; then
  echo "app_store_upload=blocked reason=missing_embedded_provisioning_profile app=\"$APP_BUNDLE\"" >&2
  exit 34
fi

TRANSPORTER_BIN="$(find_transporter)"
if [[ -z "$TRANSPORTER_BIN" ]]; then
  echo "app_store_upload=blocked reason=missing_transporter" >&2
  exit 31
fi

auth_args=()
if [[ -n "${PACE_TRANSPORTER_JWT:-}" ]]; then
  auth_args=(-jwt "$PACE_TRANSPORTER_JWT")
elif [[ -n "${PACE_ASC_API_KEY:-}" && -n "${PACE_ASC_API_ISSUER:-}" ]]; then
  auth_args=(-apiKey "$PACE_ASC_API_KEY" -apiIssuer "$PACE_ASC_API_ISSUER" -apiKeyType "${PACE_ASC_API_KEY_TYPE:-team}")
elif [[ -n "${PACE_APPLE_ID:-}" && -n "${PACE_APP_SPECIFIC_PASSWORD:-}" ]]; then
  auth_args=(-u "$PACE_APPLE_ID" -p "$PACE_APP_SPECIFIC_PASSWORD")
else
  echo "app_store_upload=blocked reason=missing_credentials required_env=PACE_TRANSPORTER_JWT or PACE_ASC_API_KEY+PACE_ASC_API_ISSUER or PACE_APPLE_ID+PACE_APP_SPECIFIC_PASSWORD" >&2
  exit 32
fi

if [[ -n "${PACE_ASC_PROVIDER:-}" ]]; then
  auth_args+=(-asc_provider "$PACE_ASC_PROVIDER")
fi

transport_args=()
if [[ -n "${PACE_TRANSPORTER_TRANSPORT:-}" ]]; then
  transport_args+=(-t "$PACE_TRANSPORTER_TRANSPORT")
fi

version_args=()
if [[ -f "$MANIFEST" ]]; then
  version="$(/usr/bin/plutil -extract version raw -o - "$MANIFEST" 2>/dev/null || true)"
  build_version="$(/usr/bin/plutil -extract build_version raw -o - "$MANIFEST" 2>/dev/null || true)"
  if [[ -n "$version" ]]; then
    version_args+=(-bundle_short_version "$version")
  fi
  if [[ -n "$build_version" ]]; then
    version_args+=(-bundle_version "$build_version")
  fi
fi

"$TRANSPORTER_BIN" -m upload -assetFile "$PKG" -platform macos -distribution AppStore "${auth_args[@]}" "${transport_args[@]}" "${version_args[@]}" -throughput -vp text -v informational
echo "app_store_upload=submitted pkg=\"$PKG\""
