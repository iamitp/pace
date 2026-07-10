#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOOLS_DIR="$ROOT_DIR/.local-tools"
PKG="$TOOLS_DIR/iTMSTransporter.pkg"
EXPANDED="$TOOLS_DIR/iTMSTransporter-expanded"
ROOT="$TOOLS_DIR/iTMSTransporter-root"
URL="${PACE_TRANSPORTER_PKG_URL:-https://itunesconnect.apple.com/WebObjects/iTunesConnect.woa/ra/resources/download/public/Transporter__OSX/bin/}"

mkdir -p "$TOOLS_DIR"

if [[ ! -f "$PKG" ]]; then
  /usr/bin/curl -L --fail --show-error --progress-bar -o "$PKG" "$URL"
fi

/usr/sbin/pkgutil --check-signature "$PKG" >"$TOOLS_DIR/iTMSTransporter-pkg-signature.txt"

rm -rf "$EXPANDED" "$ROOT"
/usr/sbin/pkgutil --expand "$PKG" "$EXPANDED"

payload="$(find "$EXPANDED" -path '*/Payload' -type f | head -n 1)"
if [[ -z "$payload" ]]; then
  echo "local_transporter=blocked reason=missing_payload" >&2
  exit 40
fi

mkdir -p "$ROOT"
(
  cd "$ROOT"
  /bin/cat "$payload" | /usr/bin/gunzip -dc | /usr/bin/cpio -idm >/dev/null 2>&1
)

if [[ ! -x "$ROOT/bin/iTMSTransporter" ]]; then
  echo "local_transporter=blocked reason=missing_binary path=\"$ROOT/bin/iTMSTransporter\"" >&2
  exit 41
fi

"$ROOT/bin/iTMSTransporter" -version >/tmp/pace-local-transporter-version.txt
/usr/bin/awk '/iTMSTransporter, version/{print "local_transporter=pass version=" $NF " path=\"'"$ROOT"'/bin/iTMSTransporter\""}' /tmp/pace-local-transporter-version.txt
