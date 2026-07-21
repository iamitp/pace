#!/bin/zsh

set -euo pipefail
umask 077

fail() {
  print -u2 -- "Sesh native integration self-test: $1"
  exit 1
}

root="${0:A:h:h}"
installer="$root/scripts/install-sesh-native-integration.sh"
source_integration="$root/../sesh/integration"
test_root="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/pace-sesh-native-test.XXXXXX")"

cleanup() {
  case "$test_root" in
    "${TMPDIR:-/tmp}"/pace-sesh-native-test.*|/tmp/pace-sesh-native-test.*)
      /bin/rm -rf "$test_root"
      ;;
  esac
}
trap cleanup EXIT

codex_home="$test_root/home/.codex"
/bin/mkdir -p "$codex_home/agents"
printf '%s\n' \
  'model = "gpt-5.6-sol"' \
  '[agents]' \
  'max_threads = 4' \
  'max_depth = 1' >"$codex_home/config.toml"
printf '%s\n' '# Existing Codex contract' 'Preserve this unrelated line.' >"$codex_home/AGENTS.md"
/bin/chmod 0600 "$codex_home/config.toml" "$codex_home/AGENTS.md"

CODEX_HOME="$codex_home" "$installer" "$source_integration" >/dev/null
/usr/bin/grep -Fxq 'Preserve this unrelated line.' "$codex_home/AGENTS.md" ||
  fail "unrelated instructions were not preserved."
[[ "$(/usr/bin/grep -Fxc '<!-- PACE_SESH_BEGIN_V1 -->' "$codex_home/AGENTS.md")" == "1" ]] ||
  fail "the managed instruction block is missing or duplicated."
[[ "$(/usr/bin/grep -Fxc '<!-- PACE_SESH_END_V1 -->' "$codex_home/AGENTS.md")" == "1" ]] ||
  fail "the managed instruction terminator is missing or duplicated."
for profile in sesh-mechanical.toml sesh-scout.toml sesh-worker.toml; do
  /usr/bin/cmp -s "$source_integration/agents/$profile" "$codex_home/agents/$profile" ||
    fail "a worker profile differs after installation: $profile"
  [[ "$(/usr/bin/stat -f '%Lp' "$codex_home/agents/$profile")" == "600" ]] ||
    fail "a worker profile is not private after installation: $profile"
done
[[ "$(/usr/bin/stat -f '%Lp' "$codex_home/agents")" == "700" ]] ||
  fail "the Codex agent directory is not private after installation."

first_hash="$(/usr/bin/shasum -a 256 "$codex_home/AGENTS.md" | /usr/bin/awk '{print $1}')"
CODEX_HOME="$codex_home" "$installer" "$source_integration" >/dev/null
second_hash="$(/usr/bin/shasum -a 256 "$codex_home/AGENTS.md" | /usr/bin/awk '{print $1}')"
[[ "$first_hash" == "$second_hash" ]] || fail "repeat installation is not idempotent."

unsafe_home="$test_root/unsafe/.codex"
/bin/mkdir -p "$unsafe_home/agents"
printf '%s\n' 'model = "gpt-5.6-sol"' '[agents]' 'max_depth = 1' >"$unsafe_home/config.toml"
printf '%s\n' 'Unrelated instructions.' >"$unsafe_home/AGENTS.md"
printf '%s\n' '# user-owned profile' 'name = "sesh-worker"' >"$unsafe_home/agents/sesh-worker.toml"
unsafe_before="$(/usr/bin/shasum -a 256 "$unsafe_home/AGENTS.md" | /usr/bin/awk '{print $1}')"
if CODEX_HOME="$unsafe_home" "$installer" "$source_integration" >/dev/null 2>&1; then
  fail "an unowned profile was accepted."
fi
unsafe_after="$(/usr/bin/shasum -a 256 "$unsafe_home/AGENTS.md" | /usr/bin/awk '{print $1}')"
[[ "$unsafe_before" == "$unsafe_after" ]] || fail "a refused install changed instructions."

print -- 'sesh_native_integration_self_test=pass'
