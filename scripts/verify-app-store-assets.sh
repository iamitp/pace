#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCREENSHOT_DIR="${PACE_APPSTORE_SCREENSHOT_DIR:-$ROOT_DIR/app-store/screenshots/mac}"

failures=()
screenshots=()
deprecated_generated_names=(
  "01-operator-hud.png"
  "02-sessions-history.png"
  "03-system-sandbox.png"
)

if [[ -d "$SCREENSHOT_DIR" ]]; then
  while IFS= read -r screenshot; do
    screenshots+=("$screenshot")
  done < <(find "$SCREENSHOT_DIR" -maxdepth 1 -type f \( -iname '*.png' -o -iname '*.jpg' -o -iname '*.jpeg' \) | sort)
fi

count=${#screenshots[@]}
echo "mac_screenshot_dir=$SCREENSHOT_DIR"
echo "mac_screenshot_count=$count"
echo "mac_screenshot_product=PaceDesk"
echo "mac_screenshot_source=rendered_artwork"
echo "mac_screenshot_dataset=review_safe_sample"

if (( count < 1 )); then
  failures+=("at least one Mac screenshot is required")
fi

if (( count > 10 )); then
  failures+=("App Store Connect allows a maximum of ten screenshots")
fi

is_accepted_mac_size() {
  case "$1x$2" in
    1280x800|1440x900|2560x1600|2880x1800)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

if (( count > 0 )); then
  for screenshot in "${screenshots[@]}"; do
    name="$(basename "$screenshot")"
    lower_name="$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]')"
    format="$(/usr/bin/sips -g format "$screenshot" 2>/dev/null | /usr/bin/awk '/format:/ {print tolower($2); exit}')"
    width="$(/usr/bin/sips -g pixelWidth "$screenshot" 2>/dev/null | /usr/bin/awk '/pixelWidth:/ {print $2; exit}')"
    height="$(/usr/bin/sips -g pixelHeight "$screenshot" 2>/dev/null | /usr/bin/awk '/pixelHeight:/ {print $2; exit}')"
    has_alpha="$(/usr/bin/sips -g hasAlpha "$screenshot" 2>/dev/null | /usr/bin/awk '/hasAlpha:/ {print tolower($2); exit}')"

    echo "mac_screenshot=$name format=${format:-unknown} size=${width:-unknown}x${height:-unknown} alpha=${has_alpha:-unknown}"

    for deprecated_name in "${deprecated_generated_names[@]}"; do
      if [[ "$name" == "$deprecated_name" ]]; then
        failures+=("deprecated generated screenshot name remains: $name")
      fi
    done

    if [[ "$lower_name" != *pacedesk* ]]; then
      failures+=("generated screenshot filename should identify PaceDesk: $name")
    fi

    case "$format" in
      png|jpeg|jpg)
        ;;
      *)
        failures+=("unsupported screenshot format for $name: ${format:-unknown}")
        ;;
    esac

    if [[ -z "$width" || -z "$height" ]] || ! is_accepted_mac_size "$width" "$height"; then
      failures+=("invalid Mac screenshot size for $name: ${width:-unknown}x${height:-unknown}")
    fi
  done
fi

if (( ${#failures[@]} > 0 )); then
  echo "app_store_assets=blocked"
  for failure in "${failures[@]}"; do
    echo "blocker=$failure"
  done
  exit 60
fi

echo "app_store_assets=pass"
