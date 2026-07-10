#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT_DIR/dist/Pace.app"
TARGET="/Applications/Pace.app"
LEGACY_TARGET="/Applications/PaceDesk.app"

"$ROOT_DIR/script/build_and_run.sh" --verify
pkill -x Headroom >/dev/null 2>&1 || true
rm -rf "$TARGET" "$LEGACY_TARGET"
/usr/bin/ditto "$APP" "$TARGET"
/usr/bin/codesign --verify --deep --strict "$TARGET"
/usr/bin/open -n "$TARGET"
sleep 1
pgrep -x Headroom >/dev/null
echo "install_local=pass target=$TARGET"
