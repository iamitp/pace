#!/bin/zsh

set -euo pipefail
umask 077

fail() {
  print -u2 -- "Pace: $1"
  exit 1
}

config_home="${SESH_CONFIG_HOME:-$HOME/.config/sesh}"
bundled_sesh="${0:A:h}/Sesh/sesh"
if [[ -n "${SESH_BIN:-}" ]]; then
  sesh_bin="$SESH_BIN"
elif [[ -x "$bundled_sesh" && ! -L "$bundled_sesh" ]]; then
  sesh_bin="$bundled_sesh"
else
  sesh_bin="$HOME/bin/sesh"
fi
cwd_file="$config_home/menu-cwd"
intent_file="$config_home/menu-launch-intent"

[[ "$config_home" == /* ]] || fail "the Sesh configuration directory must be an absolute path."
[[ "$sesh_bin" == /* ]] || fail "the Sesh command must be an absolute path."
[[ -d "$config_home" && ! -L "$config_home" ]] || fail "the Sesh configuration directory is unsafe or unavailable."
[[ -f "$cwd_file" && -r "$cwd_file" && ! -L "$cwd_file" ]] || fail "no safe managed project is selected. Choose a project in Pace first."
[[ -f "$intent_file" && -r "$intent_file" && ! -L "$intent_file" ]] || fail "no safe launch intent is selected. Start the managed task again from Pace."
[[ "$(stat -f '%Lp' "$cwd_file")" == "600" ]] || fail "the managed project record is not private. Choose the project again in Pace."
[[ "$(stat -f '%Lp' "$intent_file")" == "600" ]] || fail "the launch intent record is not private. Start the managed task again from Pace."

workspace="$(<"$cwd_file")"
launch_intent="$(<"$intent_file")"

[[ -n "$workspace" ]] || fail "the selected project is empty. Choose a project in Pace first."
[[ "$workspace" != *$'\n'* && "$workspace" != *$'\r'* ]] || fail "the selected project record is invalid. Choose the project again in Pace."
[[ "$workspace" == /* ]] || fail "the selected project must be an absolute path."
[[ -d "$workspace" ]] || fail "the selected project no longer exists. Choose a project in Pace."

canonical_workspace="$(builtin cd -P -- "$workspace" 2>/dev/null && pwd -P)" || fail "the selected project cannot be resolved."
[[ "$workspace" == "$canonical_workspace" ]] || fail "the selected project path is not canonical. Choose the project again in Pace."
[[ "$canonical_workspace" != "/" ]] || fail "the filesystem root cannot be used as a managed project."

canonical_home="$(builtin cd -P -- "$HOME" 2>/dev/null && pwd -P)" || fail "the home directory cannot be resolved."
[[ "$canonical_workspace" != "$canonical_home" ]] || fail "the whole home directory cannot be used as a managed project."

case "$launch_intent" in
  resume|new)
    ;;
  *)
    fail "the launch intent is invalid. Start the managed task again from Pace."
    ;;
esac

[[ -x "$sesh_bin" && ! -d "$sesh_bin" ]] || fail "the Sesh command is unavailable. Pace needs an executable Sesh command."

typeset -a command_argv
command_argv=("$sesh_bin" auto codex --cwd "$canonical_workspace")
if [[ "$launch_intent" == "new" ]]; then
  command_argv+=(--new)
fi

exec "${command_argv[@]}"
