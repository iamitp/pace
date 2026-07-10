#!/usr/bin/env bash
set -euo pipefail

BUNDLE_ID="${PACE_BUNDLE_ID:-com.amitpatnaik.pace}"
PROFILE_DIRS=(
  "$HOME/Library/MobileDevice/Provisioning Profiles"
  "$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"
)

profile_count=0
matching_profile_count=0

for profiles_dir in "${PROFILE_DIRS[@]}"; do
  echo "profile_dir=$profiles_dir"
  if [[ ! -d "$profiles_dir" ]]; then
    echo "  status=missing"
    continue
  fi

  while IFS= read -r profile; do
    profile_count=$((profile_count + 1))
    tmp="$(mktemp)"
    if ! /usr/bin/security cms -D -i "$profile" >"$tmp" 2>/dev/null; then
      echo "  profile=$profile status=unreadable"
      rm -f "$tmp"
      continue
    fi

    name="$(/usr/libexec/PlistBuddy -c 'Print :Name' "$tmp" 2>/dev/null || true)"
    uuid="$(/usr/libexec/PlistBuddy -c 'Print :UUID' "$tmp" 2>/dev/null || true)"
    team="$(/usr/libexec/PlistBuddy -c 'Print :TeamIdentifier:0' "$tmp" 2>/dev/null || true)"
    platform="$(/usr/libexec/PlistBuddy -c 'Print :Platform:0' "$tmp" 2>/dev/null || true)"
    appid="$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:application-identifier' "$tmp" 2>/dev/null || true)"
    expiration="$(/usr/libexec/PlistBuddy -c 'Print :ExpirationDate' "$tmp" 2>/dev/null || true)"

    if /usr/bin/grep -F "$BUNDLE_ID" "$tmp" >/dev/null; then
      matches_bundle=true
      matching_profile_count=$((matching_profile_count + 1))
    else
      matches_bundle=false
    fi

    echo "  profile=$profile"
    echo "    name=${name:-unknown}"
    echo "    uuid=${uuid:-unknown} team=${team:-unknown} platform=${platform:-unknown}"
    echo "    appid=${appid:-unknown}"
    echo "    expires=${expiration:-unknown}"
    echo "    matches_bundle=$matches_bundle"
    rm -f "$tmp"
  done < <(find "$profiles_dir" -maxdepth 1 -type f | sort)
done

echo "profile_count=$profile_count"
echo "matching_profile_count=$matching_profile_count"
