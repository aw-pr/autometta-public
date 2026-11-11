#!/usr/bin/env bash
# AUTOMETTA-CONTRACT-NONE reason=regression suite; no stage card freezes it
# dash-reaper-smoke.sh: offline check of reap_idle_dash_sessions in tick.sh.
#
# The reaper may only kill tmux viewers this tool owns: an autometta-<slug>
# session whose slug belongs to a registered subscriber, enabled or not. An
# operator's own session that merely shares the prefix (autometta-dash-run)
# used to be killed on the first tick after it was detached, as "no
# subscriber matches this slug". tmux is a stub on PATH, so the real tmux
# server is never touched.
set -euo pipefail
IFS=$'\n\t'

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

export AUTOMETTA_HOME="$tmp/home"
unset AUTOMETTA_DASH_IDLE_HOURS PHAT_CONTROLLER_DASH_IDLE_HOURS
mkdir -p "$AUTOMETTA_HOME/subscribers" "$tmp/stub" "$tmp/tmux"

cat > "$tmp/stub/tmux" <<STUB
#!/bin/sh
state='$tmp/tmux'
case "\$1" in
  list-sessions) cat "\$state/sessions" ;;
  list-clients)
    target="\${3#=}"
    if grep -Fqx "\$target" "\$state/attached"; then
      printf '/dev/ttys001: %s\n' "\$target"
    fi
    ;;
  kill-session) printf '%s\n' "\$3" >> "\$state/killed" ;;
esac
exit 0
STUB
chmod +x "$tmp/stub/tmux"
export PATH="$tmp/stub:$PATH"

# shellcheck source=./tick.sh
source "$script_dir/tick.sh"

now_epoch="$(date -u +%s)"

add_subscriber() {
  local file_name="$1" name="$2" enabled="$3" active_at="$4"
  local repo="$tmp/repos/$name"
  mkdir -p "$repo/state"
  printf '{"dash_active_at": %s}\n' "$active_at" > "$repo/state/budget.json"
  printf 'repo_path: "%s"\nenabled: %s\n' "$repo" "$enabled" \
    > "$AUTOMETTA_HOME/subscribers/$file_name"
}

add_subscriber active.yaml active true "$now_epoch"
add_subscriber idle.yaml idle true "$(( now_epoch - 2 * 86400 ))"
add_subscriber watched.yaml watched true 0
add_subscriber off.yaml off false "$now_epoch"
add_subscriber retired.yaml.disabled retired true "$now_epoch"

printf '%s\n' \
  autometta-active autometta-idle autometta-watched autometta-off \
  autometta-retired autometta-dash-run dash-run > "$tmp/tmux/sessions"
printf '%s\n' autometta-watched > "$tmp/tmux/attached"
: > "$tmp/tmux/killed"

reap_idle_dash_sessions 2> "$tmp/reaper.log"

killed_file="$tmp/tmux/killed"
failed=0
pass() { printf '  PASS: %s\n' "$1" >&2; }
fail() { printf '  FAIL: %s\n' "$1" >&2; failed=1; }
expect_spared() {
  if grep -Fqx -e "$2" -e "=$2" "$killed_file"; then fail "$1"; else pass "$1"; fi
}
expect_killed() {
  if grep -Fqx "=$2" "$killed_file"; then pass "$1"; else fail "$1"; fi
}

expect_spared "an operator session sharing the prefix is left alone" autometta-dash-run
expect_spared "a session outside the prefix is left alone" dash-run
expect_spared "an enabled subscriber with a live stage keeps its viewer" autometta-active
expect_spared "an attached viewer survives even when idle" autometta-watched
expect_killed "an idle viewer is reaped" autometta-idle
expect_killed "a disabled subscriber's viewer is reaped" autometta-off
expect_killed "a retired (.yaml.disabled) subscriber's viewer is reaped" autometta-retired
desc="kills use exact-match targets only"
if grep -qv '^=' "$killed_file"; then fail "$desc"; else pass "$desc"; fi
desc="nothing is logged about sessions the reaper does not own"
if grep -q 'dash-run' "$tmp/reaper.log"; then fail "$desc"; else pass "$desc"; fi

exit "$failed"
