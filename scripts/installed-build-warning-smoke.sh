#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# Three detector-owned fixture states, passed through the aggregate seam and
# rendered by every operator surface at both supported narrow widths.
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
fixture="$(mktemp -d)"
cleanup() {
  case "$fixture" in /tmp/*|/private/tmp/*|/private/var/*|/var/folders/*) rm -rf -- "$fixture" ;; esac
}
trap cleanup EXIT

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
assert_contains() { [[ "$1" == *"$2"* ]] || fail "$3"; }
assert_not_contains() { [[ "$1" != *"$2"* ]] || fail "$3"; }
assert_equals() { [[ "$1" == "$2" ]] || fail "$3 (got '$1', wanted '$2')"; }

checkout="$fixture/checkout"
installed="$fixture/installed"
subscriber="$fixture/subscriber"
controller="$fixture/controller"
mkdir -p "$checkout/scripts" "$installed/scripts" "$subscriber/state" \
  "$controller/subscribers" "$controller/dashboard"
printf '#!/usr/bin/env bash\nprintf fixture-current\\n\n' > "$checkout/scripts/sample.sh"
git -C "$checkout" init -q
git -C "$checkout" add scripts/sample.sh
git -C "$checkout" -c user.name=fixture -c user.email=fixture@local commit -qm fixture
checkout_sha="$(git -C "$checkout" rev-parse --short HEAD)"
cp "$checkout/scripts/sample.sh" "$installed/scripts/sample.sh"
printf '%s\n' "$checkout_sha" > "$installed/VERSION"

printf '%s\n' \
  'version: 1' 'current_stage: null' 'last_tick_at: "2026-08-26T08:00:00Z"' \
  'tick_count: 1' 'stages: []' > "$subscriber/state/state.yaml"
printf '%s\n' \
  '{"tokens_spent":0,"token_cap_total":8000000,"halted":false,"consecutive_failures":0,"consecutive_failure_cap":3}' \
  > "$subscriber/state/budget.json"
: > "$subscriber/state/cost-log.jsonl"
printf 'enabled: true\nrepo_path: "%s"\n' "$subscriber" > "$controller/subscribers/fixture.yaml"

aggregate() {
  local installed_root="$1"
  PHAT_CONTROLLER_HOME="$controller" AUTOMETTA_CHECKOUT="$checkout" \
    AUTOMETTA_INSTALLED_ROOT="$installed_root" \
    "$script_dir/heartbeat.sh" "$subscriber" >/dev/null
  PHAT_CONTROLLER_HOME="$controller" "$script_dir/aggregate-dashboard.sh" --repo "$subscriber"
}

repo_capture() {
  local payload="$1" width="$2"
  LC_ALL=C.UTF-8 TERM=xterm-256color AUTOMETTA_TICKER_PAYLOAD="$payload" \
    python3 "$script_dir/lib/repo-ticker-render.py" "$subscriber" "$width" 60 5 600
}

fleet_capture() {
  local payload="$1" width="$2" fleet_payload
  fleet_payload="$(jq -nc --argjson repo "$payload" '{repos:[$repo],fleet_totals:{},spend:{}}')"
  LC_ALL=C.UTF-8 TERM=xterm-256color AUTOMETTA_FLEET_PAYLOAD="$fleet_payload" \
    AUTOMETTA_BUILD_SHA=fixture \
    python3 "$script_dir/lib/fleet-ticker-render.py" fleet fleet "$width" 40 600
}

tui_capture() {
  local payload="$1" width="$2"
  LC_ALL=C.UTF-8 TERM=xterm-256color AUTOMETTA_TEST_PAYLOAD="$payload" \
    python3 - "$script_dir/lib/tui/render.py" "$width" <<'PY'
import importlib.util
import json
import os
import sys

spec = importlib.util.spec_from_file_location("autometta_tui_render", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
state = module.TuiState()
state.update(json.loads(os.environ["AUTOMETTA_TEST_PAYLOAD"]))
print(module.render(state, int(sys.argv[2]), 60).text())
PY
}

capture_state() {
  local label="$1" installed_root="$2" expected_status="$3"
  local payload installed_sha warning width repo_frame fleet_frame tui_frame
  payload="$(aggregate "$installed_root")" || fail "$label aggregate failed"
  assert_equals "$(jq -r '.build_check.status' <<<"$payload")" "$expected_status" \
    "$label aggregate status"
  assert_equals "$(jq -r '.build_check.checkout_sha' <<<"$payload")" "$checkout_sha" \
    "$label checkout sha did not come from the detector"
  [[ "$(jq -r '.build_check.checked_at | type' <<<"$payload")" == string ]] \
    || fail "$label payload has no check time"
  assert_not_contains "$(jq -c 'del(.build_check)' <<<"$payload")" 'build_check' \
    "$label additive field removal probe failed"

  if [[ "$expected_status" == stale ]]; then
    installed_sha="$(jq -r '.build_check.installed_sha' <<<"$payload")"
    warning="BUILD STALE installed $installed_sha, checkout $checkout_sha"
  elif [[ "$expected_status" == unreadable ]]; then
    warning="BUILD CHECK UNREADABLE"
  else
    warning=""
  fi

  for width in 80 119; do
    repo_frame="$(repo_capture "$payload" "$width")"
    fleet_frame="$(fleet_capture "$payload" "$width")"
    tui_frame="$(tui_capture "$payload" "$width")"
    if [[ -n "$warning" ]]; then
      assert_contains "$repo_frame" "$warning" "$label repo ticker $width missing warning"
      assert_contains "$fleet_frame" "$warning" "$label fleet ticker $width missing warning"
      assert_contains "$tui_frame" "$warning" "$label TUI $width missing warning"
    else
      assert_not_contains "$repo_frame" 'BUILD ' "$label repo ticker $width rendered a build line"
      assert_not_contains "$fleet_frame" 'BUILD ' "$label fleet ticker $width rendered a build line"
      assert_not_contains "$tui_frame" 'BUILD ' "$label TUI $width rendered a build line"
    fi
  done
  printf 'PASS: %s on repo, fleet and TUI at 80 and 119 columns\n' "$label"
}

capture_state current "$installed" current
printf '#!/usr/bin/env bash\nprintf fixture-stale\\n\n' > "$installed/scripts/sample.sh"
printf '496c7cc\n' > "$installed/VERSION"
capture_state stale "$installed" stale
capture_state unreadable "$fixture/no-installed-root" unreadable

jq '.build_check.checked_at = "2020-01-01T00:00:00Z"' \
  "$subscriber/state/heartbeat.json" > "$fixture/aged-heartbeat.json"
mv "$fixture/aged-heartbeat.json" "$subscriber/state/heartbeat.json"
aged_payload="$(PHAT_CONTROLLER_HOME="$controller" "$script_dir/aggregate-dashboard.sh" --repo "$subscriber")"
assert_equals "$(jq -r '.build_check.status' <<<"$aged_payload")" unreadable \
  "an over-age heartbeat verdict remained silently fresh"
printf 'PASS: an over-age heartbeat verdict becomes unreadable\n'

[[ "$(grep -c 'check-installed-build.sh.*--json' "$script_dir/heartbeat.sh")" -eq 1 ]] \
  || fail "heartbeat does not invoke the one detector exactly once"
[[ "$(grep -c 'check-installed-build.sh.*--json' "$script_dir/aggregate-dashboard.sh" || true)" -eq 0 ]] \
  || fail "aggregator reruns the expensive detector"
for consumer in aggregate-dashboard.sh lib/repo-ticker-render.py lib/fleet-ticker-render.py lib/tui/render.py; do
  [[ -z "$(grep -E 'shasum|digest\(|git[[:space:]].*diff|cmp[[:space:]]' "$script_dir/$consumer" || true)" ]] \
    || fail "$consumer contains a second build comparison"
done

set +e
invalid_output="$("$script_dir/check-installed-build.sh" --not-a-mode 2>&1)"
invalid_rc=$?
set -e
[[ "$invalid_rc" -eq 2 && "$invalid_output" == usage:* ]] \
  || fail "detector helper did not fail loudly on invalid input"

printf 'PASS: payload is additive and all figures come from one detector invocation\n'
printf 'PASS: helper failures are loud and no consumer reimplements the comparison\n'
