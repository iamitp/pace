#!/bin/zsh

set -euo pipefail
umask 077

fail() {
  print -u2 -- "managed_launcher_self_test=fail reason=$1"
  exit 1
}

root="$(mktemp -d "${TMPDIR:-/tmp}/pace-managed-launcher-test.XXXXXX")"
cleanup() {
  case "$root" in
    "${TMPDIR:-/tmp}"/pace-managed-launcher-test.*|/tmp/pace-managed-launcher-test.*)
      rm -rf "$root"
      ;;
  esac
}
trap cleanup EXIT

home="$root/home"
config="$home/.config/sesh"
project="$home/projects/project ; \$(touch PWNED)"
launcher="${0:A:h}/pace-managed-codex.command"
mkdir -p "$config" "$project"
chmod 700 "$config"
home="$(cd -P "$home" && pwd -P)"
config="$home/.config/sesh"
project="$(cd -P "$project" && pwd -P)"

write_private() {
  local value="$1"
  local target="$2"
  print -r -- "$value" >"$target"
  chmod 600 "$target"
}

write_private "$project" "$config/menu-cwd"
write_private "resume" "$config/menu-launch-intent"
resume_output="$(HOME="$home" SESH_CONFIG_HOME="$config" SESH_BIN=/bin/echo "$launcher")"
[[ "$resume_output" == "auto codex --cwd $project" ]] || fail "resume argv mismatch"

write_private "new" "$config/menu-launch-intent"
new_output="$(HOME="$home" SESH_CONFIG_HOME="$config" SESH_BIN=/bin/echo "$launcher")"
[[ "$new_output" == "auto codex --cwd $project --new" ]] || fail "new argv mismatch"
[[ ! -e "$project/PWNED" && ! -e "$root/PWNED" ]] || fail "hostile path was executed"

write_private "invalid" "$config/menu-launch-intent"
if HOME="$home" SESH_CONFIG_HOME="$config" SESH_BIN=/bin/echo "$launcher" >/dev/null 2>&1; then
  fail "invalid intent was accepted"
fi

write_private "$home" "$config/menu-cwd"
write_private "resume" "$config/menu-launch-intent"
if HOME="$home" SESH_CONFIG_HOME="$config" SESH_BIN=/bin/echo "$launcher" >/dev/null 2>&1; then
  fail "whole home workspace was accepted"
fi

write_private "$project" "$config/menu-cwd"
chmod 644 "$config/menu-cwd"
if HOME="$home" SESH_CONFIG_HOME="$config" SESH_BIN=/bin/echo "$launcher" >/dev/null 2>&1; then
  fail "non-private workspace record was accepted"
fi

sesh_fixture="$root/sesh-fixture"
sesh_launcher="$sesh_fixture/sesh"
sesh_controller="$sesh_fixture/sesh.py"
pinned_codex_directory="$home/.codex/packages/standalone/releases/0.144.3-aarch64-apple-darwin/bin"
mkdir -p "$sesh_fixture" "$pinned_codex_directory"
cp "${0:A:h}/pace-sesh" "$sesh_launcher"
chmod 755 "$sesh_launcher"
printf '%s\n' 'import os' 'print(os.environ["PATH"])' >"$sesh_controller"
printf '%s\n' '#!/bin/sh' 'exit 0' >"$pinned_codex_directory/codex"
chmod 700 "$pinned_codex_directory/codex"
resolved_path="$(HOME="$home" PATH=/usr/bin:/bin "$sesh_launcher")"
[[ "${resolved_path%%:*}" == "$pinned_codex_directory" ]] ||
  fail "pinned Codex runtime was not placed first on PATH"

print -- "managed_launcher_self_test=pass"
