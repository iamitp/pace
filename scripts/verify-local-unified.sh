#!/bin/zsh

set -euo pipefail
umask 022

fail() {
  print -u2 -- "Pace verification: $1"
  exit 1
}

root="${0:A:h:h}"
app="${1:-$root/dist/Pace-1.3.0.app}"
manifest="${2:-$root/dist/Pace-1.3.0.bundle-sha256.txt}"
binary="$app/Contents/MacOS/Headroom"
info="$app/Contents/Info.plist"
launcher="$app/Contents/Resources/Pace Managed Codex.command"
launcher_source="$root/scripts/pace-managed-codex.command"
sesh_root="$app/Contents/Resources/Sesh"
sesh_launcher="$sesh_root/sesh"
sesh_integration_installer="$sesh_root/install-native-integration"
sesh_source_root="${SESH_SOURCE_ROOT:-$root/../sesh}"
typeset -a sesh_modules
sesh_modules=(sesh.py auto.py managed.py policy_v2.py conductor.py claude_managed.py)
typeset -a sesh_agent_profiles
sesh_agent_profiles=(sesh-mechanical.toml sesh-scout.toml sesh-worker.toml sesh-reviewer.toml)

[[ "$app" == /* && -d "$app" && ! -L "$app" ]] || fail "the app path is unsafe or unavailable."
[[ -f "$binary" && -x "$binary" ]] || fail "the app binary is missing."
[[ -f "$info" ]] || fail "Info.plist is missing."
[[ -f "$launcher" && -x "$launcher" && ! -L "$launcher" ]] || fail "the managed launcher is missing or unsafe."
[[ -f "$sesh_launcher" && -x "$sesh_launcher" && ! -L "$sesh_launcher" ]] || fail "the bundled Sesh launcher is missing or unsafe."
[[ -f "$sesh_integration_installer" && -x "$sesh_integration_installer" && ! -L "$sesh_integration_installer" ]] || fail "the bundled Sesh integration installer is missing or unsafe."

/usr/bin/codesign --verify --deep --strict --verbose=2 "$app"
[[ "$(/usr/bin/plutil -extract CFBundleIdentifier raw -o - "$info")" == "com.amitpatnaik.pace" ]] || fail "bundle identifier mismatch."
[[ "$(/usr/bin/plutil -extract CFBundleShortVersionString raw -o - "$info")" == "1.3.0" ]] || fail "version mismatch."
[[ "$(/usr/bin/plutil -extract CFBundleVersion raw -o - "$info")" == "130" ]] || fail "build mismatch."
[[ "$(/usr/bin/plutil -extract LSMinimumSystemVersion raw -o - "$info")" == "13.0" ]] || fail "minimum system version mismatch."
[[ "$(/usr/bin/lipo -archs "$binary")" == "arm64" ]] || fail "the local binary must be arm64 only."
/usr/bin/xcrun vtool -show-build "$binary" | /usr/bin/grep -Eq '^[[:space:]]+minos 13\.0$' || fail "Mach-O minimum system version mismatch."
cmp -s "$launcher_source" "$launcher" || fail "the bundled launcher differs from source."
[[ "$(/usr/bin/stat -f '%Lp' "$launcher")" == "755" ]] || fail "the bundled launcher mode is not 0755."
cmp -s "$root/scripts/pace-sesh" "$sesh_launcher" || fail "the bundled Sesh launcher differs from source."
[[ "$(/usr/bin/stat -f '%Lp' "$sesh_launcher")" == "755" ]] || fail "the bundled Sesh launcher mode is not 0755."
cmp -s "$root/scripts/install-sesh-native-integration.sh" "$sesh_integration_installer" || fail "the bundled Sesh integration installer differs from source."
[[ "$(/usr/bin/stat -f '%Lp' "$sesh_integration_installer")" == "755" ]] || fail "the bundled Sesh integration installer mode is not 0755."
for module in "${sesh_modules[@]}"; do
  [[ -f "$sesh_source_root/$module" && -f "$sesh_root/$module" ]] || fail "a required Sesh module is missing: $module"
  cmp -s "$sesh_source_root/$module" "$sesh_root/$module" || fail "the bundled Sesh module differs from source: $module"
  [[ "$(/usr/bin/stat -f '%Lp' "$sesh_root/$module")" == "644" ]] || fail "the bundled Sesh module mode is not 0644: $module"
done
cmp -s "$sesh_source_root/integration/AGENTS.sesh.md" "$sesh_root/integration/AGENTS.sesh.md" || fail "the bundled native Sesh instruction fragment differs from source."
[[ "$(/usr/bin/stat -f '%Lp' "$sesh_root/integration/AGENTS.sesh.md")" == "644" ]] || fail "the bundled native Sesh instruction mode is not 0644."
cmp -s "$sesh_source_root/integration/config.sesh.toml" "$sesh_root/integration/config.sesh.toml" || fail "the bundled native Sesh config fragment differs from source."
[[ "$(/usr/bin/stat -f '%Lp' "$sesh_root/integration/config.sesh.toml")" == "644" ]] || fail "the bundled native Sesh config mode is not 0644."
for profile in "${sesh_agent_profiles[@]}"; do
  cmp -s "$sesh_source_root/integration/agents/$profile" "$sesh_root/integration/agents/$profile" || fail "a bundled native Sesh worker profile differs from source: $profile"
  [[ "$(/usr/bin/stat -f '%Lp' "$sesh_root/integration/agents/$profile")" == "644" ]] || fail "a bundled native Sesh worker profile mode is not 0644: $profile"
done

sesh_home="$(mktemp -d "${TMPDIR:-/tmp}/pace-sesh-verify.XXXXXX")"
cleanup_sesh_home() {
  case "$sesh_home" in
    "${TMPDIR:-/tmp}"/pace-sesh-verify.*|/tmp/pace-sesh-verify.*)
      rm -rf "$sesh_home"
      ;;
  esac
}
temporary=""
cleanup() {
  [[ -z "$temporary" || ! -e "$temporary" ]] || rm -f "$temporary"
  cleanup_sesh_home
}
trap cleanup EXIT
HOME="$sesh_home" SESH_CONFIG_HOME="$sesh_home/.config/sesh" "$sesh_launcher" --version | /usr/bin/grep -Fxq 'Sesh 4.2.0'
status_json="$(HOME="$sesh_home" SESH_CONFIG_HOME="$sesh_home/.config/sesh" "$sesh_launcher" --json status)"
print -r -- "$status_json" | /usr/bin/grep -Fq '"automatic": true' || fail "bundled Sesh automatic contract mismatch."
print -r -- "$status_json" | /usr/bin/grep -Fq '"schema": 3' || fail "bundled Sesh status schema mismatch."
if print -r -- "$status_json" | /usr/bin/grep -Fq '"mode"'; then
  fail "bundled Sesh still exposes a public mode."
fi

"$binary" --self-test-sesh-control | /usr/bin/grep -Fxq 'sesh_control_self_test=pass'
"$binary" --self-test-sesh-proof | /usr/bin/grep -Fxq 'sesh_proof_self_test=pass'
"$binary" --self-test-sesh-benchmark | /usr/bin/grep -Fxq 'sesh_benchmark_self_test=pass'
"$binary" --self-test-window-mapping | /usr/bin/grep -Fq 'window_mapping=pass'
"$root/scripts/self-test-managed-launcher.sh" | /usr/bin/grep -Fxq 'managed_launcher_self_test=pass'
"$root/scripts/self-test-sesh-native-integration.sh" | /usr/bin/grep -Fxq 'sesh_native_integration_self_test=pass'

[[ "$manifest" == /* ]] || fail "the manifest path must be absolute."
[[ ! -L "$manifest" ]] || fail "the manifest path must not be a symbolic link."
mkdir -p "${manifest:h}"
temporary="$(mktemp "${manifest:h}/.${manifest:t}.XXXXXX")"

while IFS= read -r -d '' packaged_file; do
  relative_path="${packaged_file#"$app"/}"
  file_sha256="$(/usr/bin/shasum -a 256 "$packaged_file" | /usr/bin/awk '{print $1}')"
  print -r -- "$file_sha256  $relative_path"
done < <(/usr/bin/find "$app" -type f -print0) | LC_ALL=C /usr/bin/sort >"$temporary"
chmod 0644 "$temporary"
mv -f "$temporary" "$manifest"

print -- "verification=pass"
print -- "app_path=$app"
print -- "manifest_path=$manifest"
print -- "bundle_manifest_sha256=$(/usr/bin/shasum -a 256 "$manifest" | /usr/bin/awk '{print $1}')"
