#!/bin/zsh

set -euo pipefail
umask 022

fail() {
  print -u2 -- "Pace install: $1"
  exit 1
}

root="${0:A:h:h}"
source_app="${1:-$root/dist/Pace-1.4.3.app}"
destination="/Applications/Pace.app"
incoming="/Applications/.Pace-1.4.3.incoming.app"
failed="/Applications/Pace.app.failed-1.4.3"
expected_executable="$destination/Contents/MacOS/Headroom"
sesh_destination="$HOME/bin/sesh"
sesh_source="$source_app/Contents/Resources/Sesh/sesh"
sesh_integration_source="$source_app/Contents/Resources/Sesh/integration"
sesh_integration_installer_source="$source_app/Contents/Resources/Sesh/install-native-integration"
sesh_staged="$HOME/bin/.pace-sesh-1.4.3.incoming"
sesh_backup="$HOME/bin/.pace-sesh.previous.$$"

[[ -d "$source_app" && ! -L "$source_app" ]] || fail "the verified source app is unavailable."
[[ -d "$destination" && ! -L "$destination" ]] || fail "the current Pace app is unavailable or unsafe."
[[ ! -e "$incoming" && ! -L "$incoming" ]] || fail "the incoming staging destination already exists."
[[ ! -e "$failed" && ! -L "$failed" ]] || fail "the failed-install preservation path already exists."
[[ "$(/usr/bin/plutil -extract CFBundleIdentifier raw -o - "$destination/Contents/Info.plist")" == "com.amitpatnaik.pace" ]] || fail "the installed app is not the expected Pace bundle."
current_version="$(/usr/bin/plutil -extract CFBundleShortVersionString raw -o - "$destination/Contents/Info.plist")"
backup="/Applications/Pace.app.rollback-$current_version"
[[ ! -e "$backup" && ! -L "$backup" ]] || fail "the rollback destination already exists."
[[ "$(/usr/bin/plutil -extract CFBundleShortVersionString raw -o - "$source_app/Contents/Info.plist")" == "1.4.3" ]] || fail "the replacement is not Pace 1.4.3."
[[ "$(/usr/bin/plutil -extract CFBundleVersion raw -o - "$source_app/Contents/Info.plist")" == "143" ]] || fail "the replacement is not build 143."
[[ -f "$sesh_source" && -x "$sesh_source" && ! -L "$sesh_source" ]] || fail "the bundled Sesh controller is missing or unsafe."
[[ -d "$sesh_integration_source" && ! -L "$sesh_integration_source" ]] || fail "the bundled native Sesh integration is missing or unsafe."
[[ -f "$sesh_integration_installer_source" && -x "$sesh_integration_installer_source" && ! -L "$sesh_integration_installer_source" ]] || fail "the bundled native Sesh installer is missing or unsafe."
/usr/bin/codesign --verify --deep --strict --verbose=2 "$source_app"

cleanup_incoming() {
  if [[ -d "$incoming" ]]; then
    case "$incoming" in
      /Applications/.Pace-1.4.3.incoming.app)
        rm -rf "$incoming"
        ;;
    esac
  fi
  if [[ -f "$sesh_staged" && ! -L "$sesh_staged" ]]; then
    case "$sesh_staged" in
      "$HOME/bin/.pace-sesh-1.4.3.incoming")
        rm -f "$sesh_staged"
        ;;
    esac
  fi
}
trap cleanup_incoming EXIT

/usr/bin/ditto "$source_app" "$incoming"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$incoming"

typeset -a old_pids
old_pids=("${(@f)$(/usr/bin/pgrep -f '^/Applications/Pace\.app/Contents/MacOS/Headroom$' || true)}")
old_pids=("${(@)old_pids:#}")
if (( ${#old_pids} > 1 )); then
  fail "more than one installed Pace process is running."
fi
if (( ${#old_pids} == 1 )); then
  /usr/bin/osascript -e 'tell application id "com.amitpatnaik.pace" to quit' >/dev/null
  for _ in {1..20}; do
    /bin/kill -0 "$old_pids[1]" 2>/dev/null || break
    /bin/sleep 0.25
  done
  /bin/kill -0 "$old_pids[1]" 2>/dev/null && fail "Pace did not quit cleanly. The app was not replaced."
fi

managed_sesh_launcher() {
  [[ -f "$sesh_destination" && ! -L "$sesh_destination" ]] || return 1
  /usr/bin/grep -Eq '^# (PACE|SESH)_MANAGED_(SESH|LAUNCHER)_V1$' "$sesh_destination"
}

mkdir -p "$HOME/bin"
if [[ -e "$sesh_staged" || -L "$sesh_staged" || -e "$sesh_backup" || -L "$sesh_backup" ]]; then
  fail "a Sesh command staging path already exists."
fi
if [[ -e "$sesh_destination" || -L "$sesh_destination" ]]; then
  managed_sesh_launcher || fail "the existing ~/bin/sesh command is not managed by Pace or Sesh."
fi

mv "$destination" "$backup"
if ! mv "$incoming" "$destination"; then
  mv "$backup" "$destination"
  fail "the replacement move failed; Pace $current_version was restored."
fi

if ! /usr/bin/codesign --verify --deep --strict --verbose=2 "$destination"; then
  mv "$destination" "$failed"
  mv "$backup" "$destination"
  fail "the installed signature failed; Pace $current_version was restored."
fi

/usr/bin/install -m 0755 "$destination/Contents/Resources/Sesh/sesh" "$sesh_staged"
if [[ -e "$sesh_destination" ]]; then
  mv "$sesh_destination" "$sesh_backup"
fi
if ! mv "$sesh_staged" "$sesh_destination"; then
  [[ ! -e "$sesh_backup" ]] || mv "$sesh_backup" "$sesh_destination"
  mv "$destination" "$failed"
  mv "$backup" "$destination"
  fail "the integrated Sesh command could not be installed; Pace $current_version was restored."
fi
if ! "$sesh_destination" --version | /usr/bin/grep -Fxq 'Sesh 5.0.0'; then
  rm -f "$sesh_destination"
  [[ ! -e "$sesh_backup" ]] || mv "$sesh_backup" "$sesh_destination"
  mv "$destination" "$failed"
  mv "$backup" "$destination"
  fail "the integrated Sesh command failed verification; Pace $current_version was restored."
fi

installed_integration_installer="$destination/Contents/Resources/Sesh/install-native-integration"
installed_integration_source="$destination/Contents/Resources/Sesh/integration"
if ! "$installed_integration_installer" "$installed_integration_source"; then
  rm -f "$sesh_destination"
  [[ ! -e "$sesh_backup" ]] || mv "$sesh_backup" "$sesh_destination"
  mv "$destination" "/Applications/Pace.app.failed-1.4.3"
  mv "$backup" "$destination"
  fail "native Codex integration failed; Pace $current_version was restored."
fi
rm -f "$sesh_backup"

/usr/bin/open "$destination"
new_pid=""
for _ in {1..20}; do
  new_pid="$(/usr/bin/pgrep -f '^/Applications/Pace\.app/Contents/MacOS/Headroom$' | /usr/bin/head -n 1 || true)"
  [[ -n "$new_pid" ]] && break
  /bin/sleep 0.25
done
[[ -n "$new_pid" ]] || fail "Pace 1.4.3 was installed but did not start. The rollback app remains available."

print -- "install=pass"
print -- "installed_app=$destination"
print -- "rollback_app=$backup"
print -- "sesh_command=$sesh_destination"
print -- "native_integration=pass"
print -- "pid=$new_pid"
print -- "version=$(/usr/bin/plutil -extract CFBundleShortVersionString raw -o - "$destination/Contents/Info.plist")"
print -- "build=$(/usr/bin/plutil -extract CFBundleVersion raw -o - "$destination/Contents/Info.plist")"
