#!/bin/zsh

set -euo pipefail
umask 077

fail() {
  print -u2 -- "Pace Sesh integration: $1"
  exit 1
}

source_root="${1:-}"
codex_home="${CODEX_HOME:-$HOME/.codex}"
agents_file="$codex_home/AGENTS.md"
config_file="$codex_home/config.toml"
agents_directory="$codex_home/agents"
source_agents="$source_root/agents"
source_fragment="$source_root/AGENTS.sesh.md"
begin_marker='<!-- PACE_SESH_BEGIN_V1 -->'
end_marker='<!-- PACE_SESH_END_V1 -->'
profile_marker='# PACE_SESH_MANAGED_PROFILE_V1'
typeset -a profiles
profiles=(sesh-mechanical.toml sesh-scout.toml sesh-worker.toml)
typeset -A had_profile
typeset -A profile_mode

[[ -n "$source_root" && "$source_root" == /* && -d "$source_root" && ! -L "$source_root" ]] ||
  fail "the bundled integration path is unsafe or unavailable."
[[ -f "$source_fragment" && ! -L "$source_fragment" ]] ||
  fail "the bundled instruction fragment is unsafe or unavailable."
[[ -d "$codex_home" && ! -L "$codex_home" ]] ||
  fail "the Codex home is unsafe or unavailable."
[[ -f "$config_file" && ! -L "$config_file" ]] ||
  fail "the Codex configuration is unsafe or unavailable."
[[ -f "$agents_file" && ! -L "$agents_file" ]] ||
  fail "the Codex instruction file is unsafe or unavailable."
[[ -d "$agents_directory" && ! -L "$agents_directory" ]] ||
  fail "the Codex agent directory is unsafe or unavailable."
agents_mode="$(/usr/bin/stat -f '%Lp' "$agents_file")"
[[ "$agents_mode" == <-> ]] || fail "the Codex instruction mode is invalid."
agents_directory_mode="$(/usr/bin/stat -f '%Lp' "$agents_directory")"
[[ "$agents_directory_mode" == <-> ]] || fail "the Codex agent directory mode is invalid."

/usr/bin/grep -Eq '^[[:space:]]*model[[:space:]]*=[[:space:]]*"gpt-5\.6-(sol|terra)"[[:space:]]*$' "$config_file" ||
  fail "Codex is not configured with a supported root model (sol or terra; the sesh on/off toggle owns the default)."
/usr/bin/grep -Eq '^[[:space:]]*max_depth[[:space:]]*=[[:space:]]*1[[:space:]]*$' "$config_file" ||
  fail "Codex does not enforce delegation depth one."

for profile in "${profiles[@]}"; do
  source_profile="$source_agents/$profile"
  destination_profile="$agents_directory/$profile"
  [[ -f "$source_profile" && ! -L "$source_profile" ]] ||
    fail "a bundled worker profile is unsafe or unavailable: $profile"
  [[ "$(/usr/bin/head -n 1 "$source_profile")" == "$profile_marker" ]] ||
    fail "a bundled worker profile lacks its ownership marker: $profile"
  if [[ -e "$destination_profile" || -L "$destination_profile" ]]; then
    had_profile[$profile]=1
    profile_mode[$profile]="$(/usr/bin/stat -f '%Lp' "$destination_profile")"
    [[ -f "$destination_profile" && ! -L "$destination_profile" ]] ||
      fail "an existing worker profile is unsafe: $profile"
    if ! /usr/bin/cmp -s "$source_profile" "$destination_profile"; then
      [[ "$(/usr/bin/head -n 1 "$destination_profile")" == "$profile_marker" ]] ||
        fail "refusing to replace an unowned worker profile: $profile"
    fi
  else
    had_profile[$profile]=0
  fi
done

stage="$(/usr/bin/mktemp -d "$codex_home/.pace-sesh-integration.XXXXXX")"
staged_agents="$stage/AGENTS.md"
stripped_agents="$stage/AGENTS.without-sesh.md"
agents_backup="$stage/AGENTS.original.md"
typeset -a existing_profiles
existing_profiles=()
committed=0

cleanup() {
  local exit_code=$?
  trap - EXIT
  if [[ "$committed" -ne 1 ]]; then
    if [[ -f "$agents_backup" ]]; then
      /usr/bin/install -m "$agents_mode" "$agents_backup" "$agents_file" || true
    fi
    for profile in "${profiles[@]}"; do
      destination_profile="$agents_directory/$profile"
      backup_profile="$stage/$profile.original"
      if [[ "${had_profile[$profile]:-0}" -eq 1 && -f "$backup_profile" ]]; then
        /usr/bin/install -m "${profile_mode[$profile]}" "$backup_profile" "$destination_profile" || true
      elif [[ "${had_profile[$profile]:-0}" -eq 0 ]]; then
        /bin/rm -f "$destination_profile"
      fi
    done
    /bin/chmod "$agents_directory_mode" "$agents_directory" || true
  fi
  case "$stage" in
    "$codex_home"/.pace-sesh-integration.*)
      /bin/rm -rf "$stage"
      ;;
  esac
  exit "$exit_code"
}
trap cleanup EXIT

/bin/cp -p "$agents_file" "$agents_backup"
set +e
/usr/bin/awk -v begin="$begin_marker" -v end="$end_marker" '
  $0 == begin {
    begin_count += 1
    if (inside || begin_count > 1) exit 71
    inside = 1
    next
  }
  $0 == end {
    end_count += 1
    if (!inside || end_count > 1) exit 72
    inside = 0
    next
  }
  !inside {
    if ($0 == "") {
      blanks = blanks "\n"
      next
    }
    if (length(blanks)) {
      printf "%s", blanks
      blanks = ""
    }
    print
  }
  END {
    if (inside || begin_count != end_count) exit 73
  }
' "$agents_file" >"$stripped_agents"
strip_status=$?
set -e
[[ "$strip_status" -eq 0 ]] || fail "the existing Sesh instruction block is malformed."

{
  /bin/cat "$stripped_agents"
  printf '\n%s\n' "$begin_marker"
  /bin/cat "$source_fragment"
  printf '%s\n' "$end_marker"
} >"$staged_agents"
/bin/chmod "$agents_mode" "$staged_agents"

for profile in "${profiles[@]}"; do
  source_profile="$source_agents/$profile"
  destination_profile="$agents_directory/$profile"
  if [[ -f "$destination_profile" ]]; then
    /bin/cp -p "$destination_profile" "$stage/$profile.original"
  fi
  /usr/bin/install -m 0600 "$source_profile" "$stage/$profile"
done

/bin/chmod 0700 "$agents_directory"
for profile in "${profiles[@]}"; do
  /usr/bin/install -m 0600 "$stage/$profile" "$agents_directory/$profile"
done
/usr/bin/install -m "$agents_mode" "$staged_agents" "$agents_file"

for profile in "${profiles[@]}"; do
  /usr/bin/cmp -s "$source_agents/$profile" "$agents_directory/$profile" ||
    fail "installed worker profile verification failed: $profile"
  [[ "$(/usr/bin/stat -f '%Lp' "$agents_directory/$profile")" == "600" ]] ||
    fail "installed worker profile mode verification failed: $profile"
done

set +e
/usr/bin/awk -v begin="$begin_marker" -v end="$end_marker" '
  $0 == begin { inside = 1; next }
  $0 == end { inside = 0; exit }
  inside { print }
' "$agents_file" >"$stage/installed-fragment.md"
extract_status=$?
set -e
[[ "$extract_status" -eq 0 ]] || fail "installed instruction extraction failed."
/usr/bin/cmp -s "$source_fragment" "$stage/installed-fragment.md" ||
  fail "installed instruction verification failed."

committed=1
print -- "native_integration=pass"
print -- "codex_agents=$agents_file"
print -- "worker_profiles=${#profiles}"
