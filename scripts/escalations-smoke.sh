#!/usr/bin/env bash
# escalations-smoke.sh: alert-status stages and halts reach the operator as
# one escalation file per episode (card 159).
#
# Everything runs against a temporary repo fixture and a temporary
# escalations folder. A recording osascript stands in for the desktop
# notification, so nothing here notifies, dispatches or spends.
set -euo pipefail
IFS=$'\n\t'

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
tmp="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$tmp"' EXIT

PHAT_CONTROLLER_HOME="$tmp/controller-home"
mkdir -p "$PHAT_CONTROLLER_HOME"
export PHAT_CONTROLLER_HOME
export AUTOMETTA_HOME="$tmp/home"

fail() {
  printf 'FAIL: 159-escalations-reach-the-operator: %s\n' "$1" >&2
  exit 1
}

# AUTOMETTA-CONTRACT-BEGIN card=stage-cards/159-escalations-reach-the-operator.md
esc="$script_dir/escalations.sh"
[[ -f "$esc" ]] || fail "scripts/escalations.sh is missing"

fake_bin="$tmp/bin"
notify_log="$tmp/osascript.log"
mkdir -p "$fake_bin"
cat > "$fake_bin/osascript" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$OSASCRIPT_LOG"
exit "${OSASCRIPT_EXIT:-0}"
SH
chmod +x "$fake_bin/osascript"
export PATH="$fake_bin:$PATH"
export OSASCRIPT_LOG="$notify_log"

export AUTOMETTA_ESCALATIONS="$tmp/escalations"
export AUTOMETTA_NOTIFY=0
pending="$AUTOMETTA_ESCALATIONS/pending"
processed="$AUTOMETTA_ESCALATIONS/processed"

repo="$tmp/fixture-repo"
mkdir -p "$repo/state/envelopes" "$repo/state/verifiers" "$repo/state/logs" \
  "$repo/state/uat/07-thing"
cat > "$repo/state/state.yaml" <<'YAML'
stages:
  - id: 05-done
    status: completed
    started_at: "2026-10-23T08:00:00Z"
  - id: 06-queued
    status: pending
  - id: 07-thing
    status: failed
    started_at: "2026-10-23T10:00:00Z"
    verifier_attempts: 0
  - id: 08-dropped
    status: superseded
    started_at: "2026-10-23T09:00:00Z"
  - id: 09-running
    status: in_progress
    started_at: "2026-10-23T11:00:00Z"
YAML
printf '{"halted":false,"halt_reason":null}\n' > "$repo/state/budget.json"
printf '{"status":"fail","notes":"ENVELOPE-NOTE-7f3a frozen contract contradicts criterion 2"}\n' \
  > "$repo/state/envelopes/07-thing.json"
: > "$repo/state/logs/07-thing-worker.log"

pending_count() {
  local n
  n="$(find "$pending" -maxdepth 1 -type f -name '*.md' 2>/dev/null | wc -l | tr -d ' ')"
  printf '%s\n' "${n:-0}"
}
only_match() {
  local pattern="$1" matches
  matches="$(find "$pending" -maxdepth 1 -type f -name "$pattern" 2>/dev/null)"
  [[ -n "$matches" && "$(printf '%s\n' "$matches" | wc -l | tr -d ' ')" == "1" ]] || return 1
  printf '%s\n' "$matches"
}
frontmatter() {
  awk 'NR == 1 && $0 == "---" { inside = 1; next } inside && $0 == "---" { exit } inside { print }' "$1"
}
has_field() {
  local file="$1" key="$2" value="$3"
  frontmatter "$file" | grep -Eq "^${key}: \"?${value}\"?\$"
}
file_id() {
  basename "$1" .md
}
state_digest() {
  cat "$repo/state/state.yaml" "$repo/state/budget.json" | shasum -a 256
}

# shellcheck source=./escalations.sh
source "$esc"
declare -F escalations_dir >/dev/null || fail "escalations_dir is not defined when sourced"
declare -F escalation_write >/dev/null || fail "escalation_write is not defined when sourced"
declare -F escalations_scan >/dev/null || fail "escalations_scan is not defined when sourced"

[[ "$(escalations_dir)" == "$tmp/escalations" ]] || fail "escalations_dir ignores AUTOMETTA_ESCALATIONS"
[[ "$(AUTOMETTA_ESCALATIONS='' AUTOMETTA_HOME="$tmp/home" escalations_dir)" == "$tmp/home/escalations" ]] \
  || fail "escalations_dir does not default to \$AUTOMETTA_HOME/escalations"

before="$(state_digest)"
escalations_scan "$repo" || fail "first scan exited non-zero"
[[ "$(pending_count)" == "1" ]] || fail "a failed stage among non-alert stages gave $(pending_count) files, expected 1"
first="$(only_match '*-fixture-repo-07-thing-failed.md')" \
  || fail "no pending file named <stamp>-fixture-repo-07-thing-failed.md"
basename "$first" | grep -Eq '^[0-9]{8}T[0-9]{6}Z-' || fail "file name does not start with a UTC stamp"
has_field "$first" repo "$repo" || fail "frontmatter repo is not the repo root"
has_field "$first" stage 07-thing || fail "frontmatter stage is not 07-thing"
has_field "$first" kind failed || fail "frontmatter kind is not the stage status"
frontmatter "$first" | grep -Eq '^created: "?[0-9]{4}-[0-9]{2}-[0-9]{2}T' || fail "frontmatter has no created timestamp"
grep -q 'ENVELOPE-NOTE-7f3a' "$first" || fail "body lacks the worker envelope notes"
grep -q 'state/uat/07-thing' "$first" || fail "body lacks the uat path"
grep -q '07-thing-worker.log' "$first" || fail "body lacks the worker log path"
[[ -s "$repo/state/escalated-episodes.json" ]] || fail "no ledger at state/escalated-episodes.json"
jq -e . "$repo/state/escalated-episodes.json" >/dev/null || fail "ledger is not JSON"
[[ "$(state_digest)" == "$before" ]] || fail "the scan changed state.yaml or budget.json"

escalations_scan "$repo" || fail "second scan exited non-zero"
[[ "$(pending_count)" == "1" ]] || fail "a second scan of an unchanged repo wrote a file"

sleep 1
yq -i '(.stages[] | select(.id == "07-thing")).started_at = "2026-10-23T12:00:00Z"' "$repo/state/state.yaml"
escalations_scan "$repo"
[[ "$(pending_count)" == "2" ]] || fail "a requeued stage failing again (new started_at) did not write a second file"

yq -i '(.stages[] | select(.id == "07-thing")).verifier_attempts = 1' "$repo/state/state.yaml"
escalations_scan "$repo"
[[ "$(pending_count)" == "3" ]] || fail "a new verifier_attempts value is not a new episode"

yq -i '.stages += [{"id": "10-judged", "status": "verifier_failed", "started_at": "2026-10-23T13:00:00Z", "verifier_attempts": 1}]' \
  "$repo/state/state.yaml"
printf '{"overall":"FAIL"}\n' > "$repo/state/verifiers/10-judged.json"
escalations_scan "$repo"
judged="$(only_match '*-fixture-repo-10-judged-verifier_failed.md')" \
  || fail "a verifier_failed stage wrote no verifier_failed file"
grep -q 'state/verifiers/10-judged.json' "$judged" || fail "body lacks the verifier artefact path"

yq -i '.stages += [{"id": "11-quiet", "status": "stalled", "started_at": "2026-10-23T14:00:00Z", "stall_marker": "no_envelope"}]' \
  "$repo/state/state.yaml"
escalations_scan "$repo"
only_match '*-fixture-repo-11-quiet-stalled.md' >/dev/null || fail "a stalled stage wrote no stalled file"
yq -i '(.stages[] | select(.id == "11-quiet")).stall_marker = "BLOCKED: needs a decision"' "$repo/state/state.yaml"
escalations_scan "$repo"
[[ "$(pending_count)" == "6" ]] || fail "a new stall_marker is not a new episode"

printf '{"halted":true,"halt_reason":"token-cap","halted_at":"2026-10-23T15:00:00Z"}\n' > "$repo/state/budget.json"
escalations_scan "$repo"
halt="$(only_match '*-fixture-repo-run-halted.md')" || fail "a halted repo wrote no <stamp>-fixture-repo-run-halted.md"
has_field "$halt" kind halted || fail "halt frontmatter kind is not halted"
grep -q 'token-cap' "$halt" || fail "halt body lacks the halt reason"
escalations_scan "$repo"
[[ "$(pending_count)" == "7" ]] || fail "a second scan of the same halt wrote a file"
printf '{"halted":true,"halt_reason":"failure-cap","halted_at":"2026-10-23T16:00:00Z"}\n' > "$repo/state/budget.json"
escalations_scan "$repo"
[[ "$(pending_count)" == "8" ]] || fail "a new halt episode did not write a file"
printf '{"halted":false,"halt_reason":null}\n' > "$repo/state/budget.json"
escalations_scan "$repo"
[[ "$(pending_count)" == "8" ]] || fail "an unhalted repo wrote a file"

[[ ! -s "$notify_log" ]] || fail "AUTOMETTA_NOTIFY=0 still called osascript"

collide_repo="$tmp/collide-repo"
mkdir -p "$collide_repo/state"
AUTOMETTA_NOTIFY=1 escalation_write "$collide_repo" 03-x note "NOTIFY-SUMMARY-1" || fail "escalation_write exited non-zero"
grep -q 'NOTIFY-SUMMARY-1' "$notify_log" 2>/dev/null || fail "notifications on did not call osascript with the summary"
AUTOMETTA_NOTIFY=1 OSASCRIPT_EXIT=1 escalation_write "$collide_repo" 03-x note "NOTIFY-SUMMARY-2" \
  || fail "a failing notification failed the write"
[[ "$(find "$pending" -name '*-collide-repo-03-x-note*.md' | wc -l | tr -d ' ')" == "2" ]] \
  || fail "two writes in the same second did not give two files"
grep -lq 'NOTIFY-SUMMARY-2' "$pending"/*-collide-repo-03-x-note*.md || fail "the write under a failing notification is missing"
detail="$tmp/detail.txt"
printf 'DETAIL-BODY-91c\n' > "$detail"
escalation_write "$collide_repo" "" note2 "summary with detail" "$detail"
detailed="$(only_match '*-collide-repo-run-note2.md')" || fail "an empty stage did not name the file run"
grep -q 'DETAIL-BODY-91c' "$detailed" || fail "the detail file is not in the body"

listing="$("$esc" list)" || fail "escalations.sh list exited non-zero"
[[ "$(printf '%s\n' "$listing" | grep -c .)" == "$(pending_count)" ]] || fail "list does not print one line per pending file"
oldest="$(file_id "$first")"
[[ "$(printf '%s\n' "$listing" | head -1)" == *"$oldest"* ]] || fail "list is not oldest first"
"$esc" show "$oldest" | grep -q 'ENVELOPE-NOTE-7f3a' || fail "show does not print the escalation"
"$esc" ack "$oldest" "ACK-NOTE-55 decided in chat" || fail "ack exited non-zero"
[[ ! -e "$pending/$oldest.md" ]] || fail "ack left the file in pending"
[[ -f "$processed/$oldest.md" ]] || fail "ack did not move the file to processed"
grep -q 'ACK-NOTE-55' "$processed/$oldest.md" || fail "ack did not append the note"
grep -qi 'acked' "$processed/$oldest.md" || fail "ack did not record an acked timestamp"
if "$esc" ack "no-such-escalation" "x" >/dev/null 2>&1; then
  fail "ack of an unknown id exited 0"
fi
[[ "$("$esc" list | grep -c .)" == "$(( $(pending_count) ))" ]] || fail "list still shows the acked file"

ctl_repo="$tmp/ctl-repo"
mkdir -p "$ctl_repo/state"
printf '{"halted":false}\n' > "$ctl_repo/state/budget.json"
printf 'stages: []\n' > "$ctl_repo/state/state.yaml"
(
  # shellcheck source=./phat-controller.sh
  source "$script_dir/phat-controller.sh"
  pc_escalate_nonblocking "$ctl_repo" "CTL-NONBLOCK-REASON" 12-y >/dev/null 2>&1
  pc_escalate_blocking "$ctl_repo" "CTL-BLOCK-REASON" >/dev/null 2>&1
) || fail "the controller escalation functions exited non-zero"
nb="$(only_match '*-ctl-repo-*-controller-nonblocking.md')" || fail "pc_escalate_nonblocking wrote no controller-nonblocking file"
grep -q 'CTL-NONBLOCK-REASON' "$nb" || fail "controller-nonblocking file lacks the reason"
bl="$(only_match '*-ctl-repo-*-controller-blocking.md')" || fail "pc_escalate_blocking wrote no controller-blocking file"
grep -q 'CTL-BLOCK-REASON' "$bl" || fail "controller-blocking file lacks the reason"

tick_repo="$tmp/tick-repo"
mkdir -p "$tick_repo/state"
printf 'stages: []\n' > "$tick_repo/state/state.yaml"
printf '{"halted":false}\n' > "$tick_repo/state/budget.json"
(
  # shellcheck source=./tick.sh
  source "$script_dir/tick.sh"
  run_heartbeat() { :; }
  warn_if_vendor_stale() { :; }
  ensure_tmux_viewer() { :; }
  sweep_repo_retention() { :; }
  _process_repo_locked() {
    printf '{"halted":true,"halt_reason":"failure-cap","halted_at":"2026-10-23T17:00:00Z"}\n' \
      > "$1/state/budget.json"
    return 0
  }
  process_repo "$tick_repo" "" >/dev/null 2>&1
) || fail "process_repo exited non-zero on the halted early-return path"
only_match '*-tick-repo-run-halted.md' >/dev/null || fail "the tick's halted early-return path did not scan"
[[ ! -d "$tick_repo/state/.tick.lock" ]] || fail "process_repo left its lock behind"

printf 'stages: []\n' > "$tick_repo/state/state.yaml"
yq -i '.stages += [{"id": "13-z", "status": "failed", "started_at": "2026-10-23T18:00:00Z"}]' "$tick_repo/state/state.yaml"
tick_rc=0
(
  source "$script_dir/tick.sh"
  run_heartbeat() { :; }
  warn_if_vendor_stale() { :; }
  ensure_tmux_viewer() { :; }
  sweep_repo_retention() { :; }
  _process_repo_locked() { return 1; }
  process_repo "$tick_repo" "" >/dev/null 2>&1
) || tick_rc=$?
[[ "$tick_rc" == "1" ]] || fail "the scan changed process_repo's return code (got $tick_rc, expected 1)"
only_match '*-tick-repo-13-z-failed.md' >/dev/null || fail "the tick's error path did not scan"

broken_rc=0
(
  source "$script_dir/tick.sh"
  run_heartbeat() { :; }
  warn_if_vendor_stale() { :; }
  ensure_tmux_viewer() { :; }
  sweep_repo_retention() { :; }
  _process_repo_locked() { return 0; }
  printf 'not a folder\n' > "$tmp/blocked"
  AUTOMETTA_ESCALATIONS="$tmp/blocked/escalations" process_repo "$tick_repo" "" >/dev/null 2>&1
) || broken_rc=$?
[[ "$broken_rc" == "0" ]] || fail "an unwritable escalations folder failed the tick (rc $broken_rc)"
[[ ! -d "$tick_repo/state/.tick.lock" ]] || fail "an unwritable escalations folder left the tick lock behind"
# AUTOMETTA-CONTRACT-END

printf 'escalations-smoke: PASS\n'
