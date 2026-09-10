#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
drain_script="$repo_root/scripts/drain.sh"
fixture="$(mktemp -d "${TMPDIR:-/tmp}/autometta-drain-scope.XXXXXX")"
if command -v realpath >/dev/null 2>&1; then
  fixture="$(realpath "$fixture")"
fi
controller="$fixture/controller"
repo_a="$fixture/repos/repo-a"
repo_b="$fixture/repos/repo-b"
repo_c="$fixture/repos/repo-c"
base_now="$(date -u +%s)"
trap 'rm -rf "$fixture"' EXIT

mkdir -p "$controller/subscribers" "$repo_a" "$repo_b" "$repo_c"
printf 'enabled: true\nweight: 1\nrepo_path: "%s"\n' "$repo_a" > "$controller/subscribers/repo-a.yaml"
printf 'enabled: true\nweight: 2\nrepo_path: "%s"\n' "$repo_b" > "$controller/subscribers/repo-b.yaml"
printf 'enabled: true\nweight: 3\nrepo_path: "%s"\n' "$repo_c" > "$controller/subscribers/repo-c.yaml"
export PHAT_CONTROLLER_HOME="$controller"

last_output=""
last_rc=0

reset_drain() {
  rm -f "$controller/drain.json" "$controller/drain.expired.json" "$controller/drain.json.lock/pid"
  rmdir "$controller/drain.json.lock" 2>/dev/null || true
}

run_start() {
  local now="$1"
  shift
  if last_output="$(AUTOMETTA_DRAIN_NOW_EPOCH="$now" "$drain_script" start "$@" 2>&1)"; then
    last_rc=0
  else
    last_rc=$?
  fi
}

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

assert_eq() {
  local expected="$1" actual="$2" label="$3"
  [[ "$actual" == "$expected" ]] || fail "$label (expected $expected, got $actual)"
}

assert_contains() {
  local haystack="$1" needle="$2" label="$3"
  [[ "$haystack" == *"$needle"* ]] || fail "$label (missing: $needle)"
}

assert_jq() {
  local filter="$1" label="$2" file="${3:-$controller/drain.json}"
  jq -e "$filter" "$file" >/dev/null || fail "$label"
}

assert_start_over_nothing() {
  reset_drain
  run_start "$base_now" --cap 50000000 --hours 2 --repo "$repo_a" --reason first
  assert_eq 0 "$last_rc" "start over nothing succeeds"
}

# Keep path-bearing jq expressions out of shell interpolation.
assert_start_over_nothing_shape() {
  assert_jq '.version == 1 and .token_cap_total == 50000000 and (.repos | length) == 1' \
    "start over nothing writes one version 1 drain"
  assert_eq "$repo_a" "$(jq -r '.repos[0]' "$controller/drain.json")" \
    "start over nothing records repo A"
  printf 'PASS case: start over nothing\n'
}

assert_live_without_replace_refuses() {
  reset_drain
  run_start "$base_now" --cap 50000000 --hours 2 --repo "$repo_a" --reason first
  assert_eq 0 "$last_rc" "first drain starts"
  run_start "$(( base_now + 30 ))" --cap 60000000 --hours 2 --repo "$repo_b" --reason second
  [[ "$last_rc" -ne 0 ]] || fail "live incompatible drain without --replace refuses"
  assert_contains "$last_output" "existing ACTIVE cap 50000000" "refusal reports cap in force"
  assert_contains "$last_output" "until " "refusal reports expiry in force"
  assert_contains "$last_output" "existing ACTIVE scope $repo_a" "refusal reports scope in force"
  assert_contains "$last_output" "Use --replace" "refusal names explicit replacement"
  assert_eq "$repo_a" "$(jq -r '.repos[0]' "$controller/drain.json")" "refusal preserves repo A"
  run_start "$(( base_now + 30 ))" --cap 50000000 --hours 1 --repo "$repo_b" --reason shorter
  [[ "$last_rc" -ne 0 ]] || fail "an earlier compatible-cap expiry refuses"
  assert_eq "$repo_a" "$(jq -r '.repos[0]' "$controller/drain.json")" \
    "earlier expiry refusal preserves repo A"
  printf 'PASS case: start over a live drain without the flag refuses\n'
}

assert_live_with_replace_replaces() {
  reset_drain
  run_start "$base_now" --cap 50000000 --hours 2 --repo "$repo_a" --reason first
  assert_eq 0 "$last_rc" "first drain starts before replacement"
  run_start "$(( base_now + 30 ))" --replace --cap 60000000 --hours 1 --repo "$repo_b" --reason replacement
  assert_eq 0 "$last_rc" "explicit replacement succeeds"
  assert_jq '.token_cap_total == 60000000 and (.repos | length) == 1' \
    "explicit replacement writes requested cap and scope"
  assert_eq "$repo_b" "$(jq -r '.repos[0]' "$controller/drain.json")" "replacement covers only repo B"
  printf 'PASS case: start over a live drain with --replace\n'
}

assert_second_repo_joins_live_drain() {
  reset_drain
  run_start "$base_now" --cap 50000000 --hours 2 --repo "$repo_a" --reason emergence
  assert_eq 0 "$last_rc" "repo A drain starts"
  local original_expiry
  original_expiry="$(jq -r '.expires_at' "$controller/drain.json")"
  run_start "$(( base_now + 30 ))" --cap 50000000 --hours 2 --repo "$repo_b" --reason autometta
  assert_eq 0 "$last_rc" "compatible repo B joins thirty seconds later"
  assert_jq '(.repos | length) == 2' "compatible join has two repos"
  jq -e --arg a "$repo_a" --arg b "$repo_b" \
    '(.repos | index($a)) != null and (.repos | index($b)) != null' \
    "$controller/drain.json" >/dev/null || fail "compatible join preserves repo A and adds repo B"
  assert_eq "$original_expiry" "$(jq -r '.expires_at' "$controller/drain.json")" \
    "compatible join retains original expiry"
  printf 'PASS case: second repo added to a live drain thirty seconds later\n'
}

assert_expiry_retires_two_repo_scope() {
  reset_drain
  run_start "$(( base_now - 7200 ))" --cap 50000000 --hours 1 --repo "$repo_a" --repo "$repo_b" --reason expired
  assert_eq 0 "$last_rc" "expired fixture drain is written"
  # shellcheck source=../scripts/budget.sh
  source "$repo_root/scripts/budget.sh"
  if budget_drain_active "$repo_a" >/dev/null 2>&1; then
    fail "expired two-repo drain remains active"
  fi
  [[ ! -f "$controller/drain.json" ]] || fail "expired drain is removed from the active path"
  assert_jq '(.repos | length) == 2' "retired drain preserves its two-repo scope" "$controller/drain.expired.json"
  printf 'PASS case: expiry retirement with two repos in scope\n'
}

assert_status_names_uncovered_subscriber() {
  reset_drain
  run_start "$base_now" --cap 50000000 --hours 2 --repo "$repo_a" --reason scoped
  assert_eq 0 "$last_rc" "scoped drain starts before status"
  local status_output
  status_output="$("$drain_script" status)"
  assert_contains "$status_output" "covered subscribers: repo-a ($repo_a)" "status names covered repo A"
  assert_contains "$status_output" "uncovered subscribers: repo-b ($repo_b)" "status names uncovered repo B"
  printf 'PASS case: status names an uncovered subscriber\n'
}

assert_version_one_is_read() {
  reset_drain
  jq -n --argjson expires "$(( base_now + 3600 ))" --arg repo "$repo_a" \
    '{version: 1, token_cap_total: 50000000, expires_at: $expires, repos: [$repo], reason: "legacy"}' \
    > "$controller/drain.json"
  local status_output
  status_output="$("$drain_script" status)"
  assert_contains "$status_output" "drain: ACTIVE cap 50000000" "version 1 drain is read by status"
  source "$repo_root/scripts/budget.sh"
  assert_eq 50000000 "$(budget_drain_active "$repo_a")" "version 1 drain is read by budget resolution"
  printf 'PASS compatibility: version 1 drain is read\n'
}

assert_concurrent_starts_union() {
  reset_drain
  local pid_a pid_b rc_a=0 rc_b=0
  AUTOMETTA_DRAIN_NOW_EPOCH="$base_now" "$drain_script" start \
    --cap 50000000 --hours 2 --repo "$repo_a" --reason concurrent-a > "$fixture/concurrent-a.log" 2>&1 &
  pid_a=$!
  AUTOMETTA_DRAIN_NOW_EPOCH="$base_now" "$drain_script" start \
    --cap 50000000 --hours 2 --repo "$repo_b" --reason concurrent-b > "$fixture/concurrent-b.log" 2>&1 &
  pid_b=$!
  wait "$pid_a" || rc_a=$?
  wait "$pid_b" || rc_b=$?
  assert_eq 0 "$rc_a" "concurrent repo A start succeeds"
  assert_eq 0 "$rc_b" "concurrent repo B start succeeds"
  jq -e --arg a "$repo_a" --arg b "$repo_b" \
    '(.repos | index($a)) != null and (.repos | index($b)) != null' \
    "$controller/drain.json" >/dev/null || fail "concurrent starts retain both repo scopes"
  printf 'PASS concurrency: two compatible starts retain both repos\n'
}

# AUTOMETTA-CONTRACT-BEGIN card=stage-cards/130-a-drain-clobbers-the-drain-it-replaces.md
assert_start_over_nothing
assert_start_over_nothing_shape
assert_live_without_replace_refuses
assert_live_with_replace_replaces
assert_second_repo_joins_live_drain
assert_expiry_retires_two_repo_scope
assert_status_names_uncovered_subscriber
assert_version_one_is_read
assert_concurrent_starts_union
# AUTOMETTA-CONTRACT-END

printf 'PASS drain scope smoke\n'
