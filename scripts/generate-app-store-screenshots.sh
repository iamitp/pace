#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT_DIR="${1:-$ROOT_DIR/app-store/screenshots/mac}"

mkdir -p "$OUTPUT_DIR"

rm -f \
  "$OUTPUT_DIR/01-operator-hud.png" \
  "$OUTPUT_DIR/02-sessions-history.png" \
  "$OUTPUT_DIR/03-system-sandbox.png" \
  "$OUTPUT_DIR/01-pacedesk-menu-hud.png" \
  "$OUTPUT_DIR/02-pacedesk-session-history.png" \
  "$OUTPUT_DIR/03-pacedesk-privacy-system.png"

/usr/bin/swift "$ROOT_DIR/scripts/render-app-store-screenshots.swift" "$OUTPUT_DIR"

echo "app_store_screenshots=pass product=\"PaceDesk\" source=\"rendered_artwork\" dataset=\"review_safe_sample\" captured_ui=false dir=\"$OUTPUT_DIR\""
