#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ICONSET="$ROOT_DIR/assets/AppIcon.iconset"
ICNS="$ROOT_DIR/assets/AppIcon.icns"

mkdir -p "$ROOT_DIR/assets"
/usr/bin/swift "$ROOT_DIR/scripts/render-app-icon.swift" "$ICONSET"
/usr/bin/iconutil -c icns "$ICONSET" -o "$ICNS"

if [[ ! -f "$ICNS" ]]; then
  echo "app_icon=blocked reason=missing_icns path=\"$ICNS\"" >&2
  exit 50
fi

echo "app_icon=pass path=\"$ICNS\""
