#!/usr/bin/env bash
set -euo pipefail

BUNDLE_ID="${PACE_BUNDLE_ID:-com.amitpatnaik.pace}"
TEAM_ID="${PACE_TEAM_ID:-AVGA7YK5X2}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROFILE_OUTPUT="${PACE_PROFILE_OUTPUT:-$ROOT_DIR/release/app-store/Pace-AppStore.provisionprofile}"
INSTALL_PROFILE=0
INPUT_PROFILE=""

usage() {
  cat >&2 <<USAGE
usage: $0 [--install] [path/to/profile.provisionprofile]

Validates a Mac App Store provisioning profile for $BUNDLE_ID and copies it to:
  $PROFILE_OUTPUT

With --install, also copies it to ~/Library/MobileDevice/Provisioning Profiles.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --install)
      INSTALL_PROFILE=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      if [[ -n "$INPUT_PROFILE" ]]; then
        usage
        exit 2
      fi
      INPUT_PROFILE="$1"
      shift
      ;;
  esac
done

if [[ -z "$INPUT_PROFILE" ]]; then
  INPUT_PROFILE="${PACE_PROVISIONING_PROFILE:-}"
fi

find_matching_profile() {
  local search_dir profile
  for search_dir in \
    "$ROOT_DIR/release/app-store" \
    "$HOME/Downloads" \
    "$HOME/Desktop" \
    "$HOME/Library/MobileDevice/Provisioning Profiles" \
    "$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"
  do
    [[ -d "$search_dir" ]] || continue
    while IFS= read -r profile; do
      if /usr/bin/security cms -D -i "$profile" 2>/dev/null | /usr/bin/grep -F "$BUNDLE_ID" >/dev/null; then
        echo "$profile"
        return 0
      fi
    done < <(find "$search_dir" -maxdepth 1 -type f \( -name '*.provisionprofile' -o -name '*.mobileprovision' \) -exec /bin/ls -t {} + 2>/dev/null || true)
  done
}

if [[ -z "$INPUT_PROFILE" ]]; then
  INPUT_PROFILE="$(find_matching_profile || true)"
fi

if [[ -z "$INPUT_PROFILE" || ! -f "$INPUT_PROFILE" ]]; then
  echo "profile_import=blocked reason=missing_profile bundle_id=$BUNDLE_ID" >&2
  exit 70
fi

decoded="$(mktemp)"
trap 'rm -f "$decoded"' EXIT

if ! /usr/bin/security cms -D -i "$INPUT_PROFILE" >"$decoded" 2>/dev/null; then
  echo "profile_import=blocked reason=unreadable_profile path=\"$INPUT_PROFILE\"" >&2
  exit 71
fi

name="$(/usr/bin/plutil -extract Name raw -o - "$decoded" 2>/dev/null || true)"
uuid="$(/usr/bin/plutil -extract UUID raw -o - "$decoded" 2>/dev/null || true)"
team="$(/usr/bin/plutil -extract TeamIdentifier.0 raw -o - "$decoded" 2>/dev/null || true)"
platform="$(/usr/bin/plutil -extract Platform.0 raw -o - "$decoded" 2>/dev/null || true)"
expiration="$(/usr/bin/plutil -extract ExpirationDate raw -o - "$decoded" 2>/dev/null || true)"
app_id="$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:com.apple.application-identifier' "$decoded" 2>/dev/null || true)"

if [[ "$team" != "$TEAM_ID" ]]; then
  echo "profile_import=blocked reason=team_mismatch expected=$TEAM_ID actual=${team:-missing} path=\"$INPUT_PROFILE\"" >&2
  exit 72
fi

if [[ "$platform" != "OSX" && "$platform" != "MAC_OS" ]]; then
  echo "profile_import=blocked reason=platform_mismatch expected=OSX actual=${platform:-missing} path=\"$INPUT_PROFILE\"" >&2
  exit 73
fi

if ! /usr/bin/grep -F "$BUNDLE_ID" "$decoded" >/dev/null; then
  echo "profile_import=blocked reason=bundle_mismatch expected=$BUNDLE_ID app_id=${app_id:-missing} path=\"$INPUT_PROFILE\"" >&2
  exit 74
fi

if [[ -z "$expiration" ]]; then
  echo "profile_import=blocked reason=missing_expiration path=\"$INPUT_PROFILE\"" >&2
  exit 75
fi

expiration_epoch="$(/bin/date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$expiration" +%s 2>/dev/null || true)"
now_epoch="$(/bin/date -u +%s)"
if [[ -z "$expiration_epoch" || "$expiration_epoch" -le "$now_epoch" ]]; then
  echo "profile_import=blocked reason=profile_expired expires=${expiration:-unknown} path=\"$INPUT_PROFILE\"" >&2
  exit 76
fi

mkdir -p "$(dirname "$PROFILE_OUTPUT")"
cp "$INPUT_PROFILE" "$PROFILE_OUTPUT"

if [[ "$INSTALL_PROFILE" == "1" || "${PACE_INSTALL_PROFILE:-0}" == "1" ]]; then
  if [[ -z "$uuid" ]]; then
    echo "profile_import=blocked reason=missing_uuid path=\"$INPUT_PROFILE\"" >&2
    exit 77
  fi
  install_dir="$HOME/Library/MobileDevice/Provisioning Profiles"
  mkdir -p "$install_dir"
  cp "$INPUT_PROFILE" "$install_dir/$uuid.provisionprofile"
  echo "profile_install=pass path=\"$install_dir/$uuid.provisionprofile\""
fi

echo "profile_import=pass path=\"$PROFILE_OUTPUT\" name=\"${name:-unknown}\" uuid=\"${uuid:-unknown}\" team=\"$team\" platform=\"$platform\" expires=\"$expiration\" app_id=\"${app_id:-unknown}\""
